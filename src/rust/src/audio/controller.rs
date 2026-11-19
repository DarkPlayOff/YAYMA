use foldhash::HashMap;
use parking_lot::RwLock;
use rodio::Source;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::Mutex;
use yandex_music::model::track::{Track, TrackFade};

use crate::audio::{
    commands::AudioMessage,
    fx::{
        EffectHandle, FxSource,
        modules::{FadeEffect, MonitorEffect},
        param::EffectParams,
    },
    monitor::Monitor,
    playback::PlaybackEngine,
    progress::TrackProgress,
    signals::AudioSignals,
    stream_manager::{PreparedStream, StreamManager},
};
use crate::stream::BufferingGate;

// Gapless preheat tuning, after the Yandex Music client's "preheat + swap"
// scheme: the prewarmed next session is parked on the engine's second player
// this far before the end of the current track, requests are retried while
// the prewarm session is still building, and the boundary swap gets a short
// grace at the track end before the poll-based fallback takes over.
const PREHEAT_AHEAD_MS: u64 = 15_000;
const PREHEAT_TOO_LATE_MS: u64 = 1_000;
const PREHEAT_RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);
const PREHEAT_SWAP_GRACE: std::time::Duration = std::time::Duration::from_millis(1_500);
const CROSSFADE_RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);

/// Overlap window (ms) derived from the outgoing track's server fade-out
/// region: the crossfade starts at `out_start` and runs to the end of the
/// track. Mirrors the official client's SmartCrossfade, which aligns the
/// fade regions delivered with the track metadata; the user setting is the
/// fallback when the region is absent or degenerate. Capped at the preheat
/// arming window, which bounds how early the transition can begin.
fn server_fade_out_window_ms(fade: &TrackFade, duration_ms: u64) -> Option<u64> {
    if duration_ms == 0 || fade.out_start <= 0.0 {
        return None;
    }
    let out_start_ms = (fade.out_start as f64 * 1000.0) as u64;
    if out_start_ms >= duration_ms {
        return None;
    }
    Some((duration_ms - out_start_ms).min(PREHEAT_AHEAD_MS))
}

/// Incoming fade-in window (ms): from the track start to `in_stop`. Regions
/// starting deep into the track are approximated by a ramp from zero over
/// `in_stop` — fade-ins normally begin at zero anyway.
fn server_fade_in_window_ms(fade: &TrackFade) -> Option<u64> {
    if fade.in_stop <= 0.0 {
        return None;
    }
    Some(((fade.in_stop as f64 * 1000.0) as u64).min(PREHEAT_AHEAD_MS))
}

/// One migrated user-FX parameter set: from the outgoing track's effect
/// handle onto the incoming source's handle.
struct FxMigration {
    old: EffectHandle,
    new: EffectHandle,
    applied: Vec<f32>,
    enabled: bool,
}

/// The parked next-track session on the engine's second player, armed by
/// `preheat_next` and consumed by `activate_preheat` at the track boundary.
struct PreheatState {
    track: Track,
    progress: Arc<TrackProgress>,
    buffering: Arc<BufferingGate>,
    handles: HashMap<String, EffectHandle>,
    migrations: Vec<FxMigration>,
    // playback_generation the preheat was armed under; the swap is rejected
    // when the generation moved (a skip/stop/reload landed meanwhile).
    generation: u64,
}

pub struct AudioController {
    engine: Arc<PlaybackEngine>,
    stream_manager: Arc<StreamManager>,
    tx: tokio::sync::mpsc::Sender<AudioMessage>,
    error_sink: Arc<dyn Fn(String) + Send + Sync>,
    // Stable PositionClock: the same instance QueueManager holds; never replaced.
    progress_clock: Arc<TrackProgress>,
    // Current stream-written per-track progress, mirrored into the clock.
    progress_source: Arc<parking_lot::Mutex<Option<Arc<TrackProgress>>>>,
    current_playback_task: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    // Monitor loop owned by this instance; aborted in shutdown()/Drop.
    monitor_task: parking_lot::Mutex<Option<tokio::task::JoinHandle<()>>>,
    // Bumped on every stop()/play_track() call so an in-flight playback task that has
    // already passed its last `.await` (and so can no longer be cancelled by `task.abort()`)
    // can still detect it's been superseded and skip touching the engine/signals.
    playback_generation: Arc<AtomicU64>,
    // Mirrors the original player's mediaElementErrorReloadCount: a stream
    // that ends before the known track duration gets two recovery attempts
    // before it is treated as a normal end/error.
    stream_error_retries: Arc<AtomicU8>,
    reload_in_flight: Arc<AtomicU8>,
    // Set by an explicit pause and cleared by resume/new track. A stream that
    // finishes preparing after the user hit pause must not start playing.
    pause_requested: Arc<AtomicBool>,
    transient_volume_gain: Arc<AtomicU8>,
    signals: AudioSignals,
    effect_handles: Arc<RwLock<HashMap<String, EffectHandle>>>,
    // Gapless: metadata for the session parked on the engine's second player.
    // Shared with monitor-loop clones (they invalidate it on swap timeout).
    preheat: Arc<parking_lot::Mutex<Option<PreheatState>>>,
    // Crossfade state: in-flight marker, request marker (set by the
    // BeginCrossfade handler, consumed by the advance path) and an epoch that
    // invalidates running fade animations on stop/hard swaps.
    crossfade_active: Arc<AtomicBool>,
    crossfade_requested: Arc<AtomicBool>,
    fade_epoch: Arc<AtomicU64>,
    // Server-driven overlap window (ms) of the CURRENT track's fade-out
    // region, refreshed on every track change; 0 = no region, fall back to
    // the user setting. Read by the monitor's crossfade trigger.
    crossfade_out_window_ms: Arc<AtomicU64>,
}

// Shares everything except monitor ownership: only the instance built by
// new() owns (and aborts) the monitor loop; clones hold no handle.
impl Clone for AudioController {
    fn clone(&self) -> Self {
        Self {
            engine: self.engine.clone(),
            stream_manager: self.stream_manager.clone(),
            tx: self.tx.clone(),
            error_sink: self.error_sink.clone(),
            progress_clock: self.progress_clock.clone(),
            progress_source: self.progress_source.clone(),
            current_playback_task: self.current_playback_task.clone(),
            monitor_task: parking_lot::Mutex::new(None),
            playback_generation: self.playback_generation.clone(),
            stream_error_retries: self.stream_error_retries.clone(),
            reload_in_flight: self.reload_in_flight.clone(),
            pause_requested: self.pause_requested.clone(),
            transient_volume_gain: self.transient_volume_gain.clone(),
            signals: self.signals.clone(),
            effect_handles: self.effect_handles.clone(),
            preheat: self.preheat.clone(),
            crossfade_active: self.crossfade_active.clone(),
            crossfade_requested: self.crossfade_requested.clone(),
            fade_epoch: self.fade_epoch.clone(),
            crossfade_out_window_ms: self.crossfade_out_window_ms.clone(),
        }
    }
}

impl Drop for AudioController {
    fn drop(&mut self) {
        // Owner-only: clones hold None. Abort is idempotent.
        if let Some(handle) = self.monitor_task.lock().take() {
            handle.abort();
        }
    }
}

impl AudioController {
    pub fn new(
        engine: PlaybackEngine,
        stream_manager: Arc<StreamManager>,
        tx: tokio::sync::mpsc::Sender<AudioMessage>,
        error_sink: Arc<dyn Fn(String) + Send + Sync>,
        signals: AudioSignals,
        progress_clock: Arc<TrackProgress>,
    ) -> Self {
        let effect_handles = crate::audio::fx::init::create_templates();
        let controller = Self {
            engine: Arc::new(engine),
            stream_manager,
            tx,
            error_sink,
            progress_clock,
            progress_source: Arc::new(parking_lot::Mutex::new(None)),
            current_playback_task: Arc::new(Mutex::new(None)),
            monitor_task: parking_lot::Mutex::new(None),
            playback_generation: Arc::new(AtomicU64::new(0)),
            stream_error_retries: Arc::new(AtomicU8::new(0)),
            reload_in_flight: Arc::new(AtomicU8::new(0)),
            pause_requested: Arc::new(AtomicBool::new(false)),
            transient_volume_gain: Arc::new(AtomicU8::new(100)),
            signals,
            effect_handles: Arc::new(RwLock::new(effect_handles)),
            preheat: Arc::new(parking_lot::Mutex::new(None)),
            crossfade_active: Arc::new(AtomicBool::new(false)),
            crossfade_requested: Arc::new(AtomicBool::new(false)),
            fade_epoch: Arc::new(AtomicU64::new(0)),
            crossfade_out_window_ms: Arc::new(AtomicU64::new(0)),
        };

        controller.start_monitor();
        controller
    }

    fn start_monitor(&self) {
        let engine = self.engine.clone();
        let progress_clock = self.progress_clock.clone();
        let progress_source = self.progress_source.clone();
        let signals = self.signals.clone();
        let tx = self.tx.clone();
        let error_sink = self.error_sink.clone();
        let controller = self.clone();
        let stream_error_retries = self.stream_error_retries.clone();
        let reload_in_flight = self.reload_in_flight.clone();

        let handle = tokio::spawn(async move {
            let mut buffering_duration = std::time::Duration::ZERO;
            let check_interval = std::time::Duration::from_millis(125);
            // First tick the sink was observed empty while a gapless swap was
            // expected; bounds how long the boundary watch has to land.
            let mut empty_since: Option<std::time::Instant> = None;
            // Throttle for PreheatNext requests while the prewarm session for
            // the next track is still being built.
            let mut last_preheat_request: Option<std::time::Instant> = None;
            // Throttle for BeginCrossfade requests (retry when the actor
            // rejected a racing attempt).
            let mut last_crossfade_request: Option<std::time::Instant> = None;

            loop {
                tokio::time::sleep(check_interval).await;

                let is_playing = signals.is_playing.get();
                let is_buffering = signals.is_buffering.get();

                if is_playing && is_buffering {
                    buffering_duration += check_interval;
                    if buffering_duration >= std::time::Duration::from_secs(15) {
                        error_sink("Buffering timed out after 15s, playback paused".to_string());
                        controller.pause().await;
                        signals.set_buffering(false);
                        buffering_duration = std::time::Duration::ZERO;
                    }
                } else {
                    buffering_duration = std::time::Duration::ZERO;
                }

                if is_playing && !is_buffering {
                    // Mirror stream-written counters into the stable clock.
                    if let Some(src) = progress_source.lock().as_ref().cloned() {
                        progress_clock.sync_stream_state(&src);
                    }

                    if engine.is_empty() {
                        let position = engine.pos();
                        let duration_ms = signals.duration_ms.get();
                        let ended_early = duration_ms > 0
                            && position.as_millis().saturating_add(1_000) < duration_ms as u128;

                        // With a preheat parked, the boundary watch thread fires
                        // within milliseconds of the queue draining and the actor
                        // swaps the players. Give it a short grace before the
                        // poll fallback below takes over.
                        if engine.has_preheat() && !ended_early {
                            let since = *empty_since.get_or_insert(std::time::Instant::now());
                            if since.elapsed() < PREHEAT_SWAP_GRACE {
                                continue;
                            }
                            // The swap never landed (lost watch thread, queue
                            // mismatch): give up on the preheat and let the
                            // regular poll-based advance handle the end.
                            controller.drop_preheat();
                        }
                        empty_since = None;

                        if ended_early
                            && stream_error_retries.load(Ordering::SeqCst) < 2
                            && reload_in_flight
                                .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
                                .is_ok()
                        {
                            stream_error_retries.fetch_add(1, Ordering::SeqCst);
                            signals.set_buffering(true);
                            // Non-blocking: never stall the monitor on a full actor queue.
                            if tx.try_send(AudioMessage::ReloadCurrentTrack).is_err() {
                                reload_in_flight.store(0, Ordering::SeqCst);
                            }
                            continue;
                        }

                        stream_error_retries.store(0, Ordering::SeqCst);
                        signals.set_playing(false);
                        signals.is_stopped.set(true);
                        let _ = tx.try_send(AudioMessage::TrackEnded);
                        continue;
                    }
                    empty_since = None;

                    // engine.pos() is the single source of position here;
                    // position_ms (signals) and TrackProgress (clock) are mirrors of it.
                    if signals.monitor.is_focused() {
                        let pos = engine.pos();
                        let dur = signals.duration_ms.get();

                        signals.update_progress(pos.as_millis() as u64, dur);

                        progress_clock.set_current_position(pos);
                        let buffered = progress_clock.get_buffered_ratio() as f32;
                        signals.update_buffered_ratio(buffered);
                    } else {
                        // Keep position fresh while unfocused: Prev threshold
                        // and reload use position_ms, only the buffering ratio
                        // (and other heavy UI updates) stay gated.
                        let pos = engine.pos();
                        signals.update_progress(pos.as_millis() as u64, signals.duration_ms.get());
                        progress_clock.set_current_position(pos);
                    }

                    // Gapless preheat: ask the actor to park the prewarmed
                    // next session near the track's end (idempotent, retried
                    // while the prewarm session is still building).
                    let duration_ms = signals.duration_ms.get();
                    if duration_ms > 0 {
                        let remaining = duration_ms.saturating_sub(signals.position_ms.get());
                        if remaining <= PREHEAT_AHEAD_MS
                            && remaining > PREHEAT_TOO_LATE_MS
                            && !engine.has_preheat()
                            && last_preheat_request
                                .is_none_or(|t| t.elapsed() >= PREHEAT_RETRY_INTERVAL)
                        {
                            last_preheat_request = Some(std::time::Instant::now());
                            // Non-blocking: never stall the monitor on a full actor queue.
                            let _ = tx.try_send(AudioMessage::PreheatNext);
                        }

                        // Crossfade: with the preheat parked and the fade
                        // window reached (server fade region when present,
                        // the user setting otherwise), start the overlap
                        // transition. Windows are capped at the preheat
                        // arming window, so this request always lands before
                        // the boundary watch fires.
                        let user_ms = u64::from(signals.crossfade_ms.get());
                        if user_ms > 0 {
                            let stored = controller.crossfade_out_window_ms();
                            let window = if stored > 0 { stored } else { user_ms };
                            if remaining <= window
                                && remaining > 0
                                && engine.has_preheat()
                                && controller.crossfade_ready_to_start()
                                && last_crossfade_request
                                    .is_none_or(|t| t.elapsed() >= CROSSFADE_RETRY_INTERVAL)
                            {
                                last_crossfade_request = Some(std::time::Instant::now());
                                let _ = tx.try_send(AudioMessage::BeginCrossfade);
                            }
                        }
                    }
                }
            }
        });
        *self.monitor_task.lock() = Some(handle);
    }

    /// Abort the monitor loop and any in-flight playback task. Idempotent.
    pub async fn shutdown(&self) {
        if let Some(handle) = self.monitor_task.lock().take() {
            handle.abort();
        }
        let mut task_guard = self.current_playback_task.lock().await;
        if let Some(task) = task_guard.take() {
            task.abort();
        }
    }

    pub async fn replace_track(&self, track: Track, position_ms: u64) {
        let start_paused = !self.signals.is_playing.get();
        let start_pos = std::time::Duration::from_millis(position_ms);
        // Use soft_reload = true to avoid resetting playback signals
        self.play_track(track, start_paused, start_pos, true).await;
    }

    pub fn invalidate_track(&self, track_id: &str) {
        self.stream_manager.invalidate_track(track_id);
    }

    pub async fn recreate_engine(
        &self,
        device_name: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Engine recreation replaces the whole state, including any parked
        // preheat player; drop the stale preheat metadata along with it.
        self.preheat.lock().take();
        self.crossfade_active.store(false, Ordering::SeqCst);
        self.fade_epoch.fetch_add(1, Ordering::SeqCst);
        // Opening an output device is blocking ALSA/pulse work. On a wedged
        // pipewire-pulse it can hang far past any server timeout, and running
        // it on the audio actor would freeze every control button behind it.
        // The blocking thread cannot be cancelled; after the deadline it is
        // abandoned (one leaked thread while the device is wedged, instead of
        // a dead app). The deadline is generous on purpose: slow-but-alive
        // servers must finish the open (a recreate that fails here has to wait
        // for the next stream error to be retried); only a truly dead one
        // hits it.
        // shortcut: no recreate backoff/serialization; bounded by this deadline.
        const DEVICE_OPEN_TIMEOUT: Duration = Duration::from_secs(60);
        let engine = self.engine.clone();
        let device_name = device_name.map(str::to_string);
        match tokio::time::timeout(
            DEVICE_OPEN_TIMEOUT,
            tokio::task::spawn_blocking(move || engine.recreate(device_name.as_deref())),
        )
        .await
        {
            Ok(result) => result
                .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))?,
            Err(_) => {
                tracing::error!("device_open_timed_out");
                Err("audio device open timed out".into())
            }
        }
    }

    // --- Gapless preheat -------------------------------------------------

    /// A preheated next-track session is parked on the engine's second player
    /// and still valid for the current playback generation.
    pub fn has_preheat(&self) -> bool {
        self.preheat.lock().is_some() && self.engine.has_preheat()
    }

    pub fn engine_is_empty(&self) -> bool {
        self.engine.is_empty()
    }

    /// Arms the gapless preheat for `next` (the queue's peeked successor).
    /// Never blocks on the network: adopts the prewarm session only when it
    /// is already built — the monitor re-requests on later ticks otherwise.
    pub fn preheat_next(&self, next: Track) {
        if self.preheat.lock().is_some() {
            return;
        }
        // Under repeat-single the preheat parks a replay of the current track
        // itself; in every other mode a peeked successor equal to the current
        // track is a stale request racing a skip and must be ignored.
        let repeat_single =
            self.signals.repeat_mode.get() == crate::audio::enums::RepeatMode::Single;
        if !repeat_single
            && self.signals.current_track_id.get().as_deref() == Some(next.id.as_str())
        {
            return;
        }
        let Some(prepared) = self.stream_manager.adopt_prewarmed(&next.id) else {
            return;
        };
        let generation = self.playback_generation.load(Ordering::SeqCst);
        let PreparedStream {
            session,
            progress,
            buffering,
            ..
        } = prepared;

        let source = build_fx_source(session.source, &next, &self.signals.monitor);
        let pending_handles = source.get_effect_handles();
        // Snapshot the outgoing track's FX state onto the new handles now;
        // they are published only at the swap, so the still-audible current
        // track keeps receiving UI writes until then.
        let migrations = snapshot_fx_migrations(&self.effect_handles, &pending_handles);

        self.engine.preheat_source(source);
        *self.preheat.lock() = Some(PreheatState {
            track: next.clone(),
            progress,
            buffering,
            handles: pending_handles,
            migrations,
            generation,
        });

        self.spawn_boundary_watch();
        tracing::info!(track_id = %next.id, "gapless preheat armed");
    }

    /// One-shot thread that fires `BoundaryCrossed` at the sample-accurate end
    /// of the current source (`Player::sleep_until_end` completes exactly when
    /// the queue drains). A player stopped early by skip/stop/reload also
    /// completes it — such stale firings are filtered in the handler.
    fn spawn_boundary_watch(&self) {
        let Some(player) = self.engine.current_player() else {
            return;
        };
        let tx = self.tx.clone();
        if let Err(e) = std::thread::Builder::new()
            .name("gapless-boundary".into())
            .spawn(move || {
                player.sleep_until_end();
                let _ = tx.try_send(AudioMessage::BoundaryCrossed);
            })
        {
            tracing::warn!(error = %e, "boundary watch thread spawn failed");
        }
    }

    /// Whether the parked preheat belongs to `track_id` under the current
    /// generation — the check the unified advance path uses to swap instead
    /// of cold-starting the next track.
    pub fn can_activate_preheat(&self, track_id: &str) -> bool {
        let guard = self.preheat.lock();
        match guard.as_ref() {
            Some(state) => {
                state.generation == self.playback_generation.load(Ordering::SeqCst)
                    && state.track.id == track_id
                    && self.engine.has_preheat()
            }
            None => false,
        }
    }

    /// Takes the parked preheat for `track`, validating the generation and the
    /// track identity; on mismatch the parked slot is discarded and `None` is
    /// returned (the caller falls back to the cold path).
    fn claim_preheat(&self, track: &Track) -> Option<PreheatState> {
        let state = self.preheat.lock().take()?;
        if state.generation != self.playback_generation.load(Ordering::SeqCst)
            || state.track.id != track.id
        {
            self.engine.drop_preheat();
            return None;
        }
        Some(state)
    }

    /// Repoints every piece of controller state at the promoted session: FX
    /// handle publication (with the bounded re-verify), the stable progress
    /// clock, the buffering gate and the recovery counters.
    fn publish_preheated(&self, state: PreheatState) {
        let PreheatState {
            progress,
            buffering,
            handles,
            mut migrations,
            ..
        } = state;

        // Publish the preheated source's FX handles and close the lost-update
        // window with the same bounded re-verify the play_track path uses:
        // UI writes that landed on the old handles since the preheat snapshot
        // are re-applied to the now-visible new handles.
        {
            let mut store = self.effect_handles.write();
            *store = handles;
        }
        for _ in 0..4 {
            if reapply_fx_migrations(&mut migrations) {
                break;
            }
        }

        // Publish into the stable clock (never swapped): reset, seed the
        // stream counters, remember the stream-written source for the
        // monitor mirror. Same contract as play_track.
        self.progress_clock.reset();
        self.progress_clock.sync_stream_state(&progress);
        *self.progress_source.lock() = Some(progress);

        // From here on this session drives the output, so let it report
        // buffering (the gate was built disarmed in the prewarm path, and a
        // parked session's stalls must not raise the spinner over the track
        // that is still playing).
        {
            let signals = self.signals.clone();
            let generation = self.playback_generation.clone();
            let my_generation = self.playback_generation.load(Ordering::SeqCst);
            buffering.arm(std::sync::Arc::new(move |is_buffering| {
                if generation.load(Ordering::SeqCst) == my_generation {
                    signals.set_buffering(is_buffering);
                }
            }));
        }

        self.stream_error_retries.store(0, Ordering::SeqCst);
        self.reload_in_flight.store(0, Ordering::SeqCst);
    }

    /// Signal tail shared by both promotion paths: the new track becomes
    /// current, progress restarts from zero.
    fn finish_promotion(&self, track: Track) {
        self.update_crossfade_out_window(&track);
        self.signals.set_current_track(Some(track));
        self.signals.set_buffering(false);
        self.signals
            .update_progress(0, self.signals.duration_ms.get());

        // Pausing right at the boundary must not start the next track.
        if self.pause_requested.load(Ordering::SeqCst) {
            self.engine.pause();
            self.signals.set_playing(false);
        } else {
            self.engine.play();
            self.signals.set_playing(true);
        }
    }

    /// The boundary swap: promotes the parked player (the audio pipeline stays
    /// intact), then repoints every piece of controller state at the new track.
    /// The queue must already be advanced to `track` by the caller.
    pub fn activate_preheat(&self, track: Track) {
        let Some(state) = self.claim_preheat(&track) else {
            return;
        };
        self.publish_preheated(state);

        if !self.engine.activate_preheat() {
            // The parked player vanished (engine recreated between arming and
            // the swap). Leave the signals alone; the monitor's empty-poll
            // fallback recovers the advance.
            tracing::warn!("gapless_swap_failed");
            return;
        }
        // A hard swap cancels any fade animation still running.
        self.fade_epoch.fetch_add(1, Ordering::SeqCst);
        self.crossfade_active.store(false, Ordering::SeqCst);

        tracing::info!(track_id = %track.id, "gapless swap at boundary");
        self.finish_promotion(track);
    }

    /// The crossfade swap: promotes the parked player while the previous one
    /// keeps playing into the fade-out window. The queue must already be
    /// advanced to `track` by the caller.
    ///
    /// Overlap windows are per-side: a track's own server fade region wins
    /// where present (SmartCrossfade-style alignment — the outgoing fades over
    /// its fade-out region, the incoming over its fade-in region), the user
    /// setting fills the gaps. Both tracks' baked `FadeEffect`s are disabled
    /// for the transition: the ramp replaces them, otherwise the fades would
    /// stack into a double fade.
    pub fn begin_crossfade(&self, track: Track) {
        let Some(state) = self.claim_preheat(&track) else {
            return;
        };

        let user_ms = u64::from(self.signals.crossfade_ms.get().max(1));
        let duration_ms = self.signals.duration_ms.get();
        let out_ms = self
            .signals
            .current_track
            .get()
            .as_ref()
            .and_then(|t| t.fade.as_ref())
            .and_then(|fade| server_fade_out_window_ms(fade, duration_ms))
            .unwrap_or(user_ms)
            .clamp(100, PREHEAT_AHEAD_MS);
        let in_ms = track
            .fade
            .as_ref()
            .and_then(server_fade_in_window_ms)
            .unwrap_or(user_ms)
            .clamp(100, PREHEAT_AHEAD_MS);

        // The outgoing track's baked fade (its handle is still in the store
        // until the incoming one is published) must not stack with the ramp.
        if let Some(fade) = self.effect_handles.read().get("fade") {
            fade.set_enabled(false);
        }

        self.publish_preheated(state);

        // Same for the incoming track's baked fade-in, just published.
        if let Some(fade) = self.effect_handles.read().get("fade") {
            fade.set_enabled(false);
        }

        if !self.engine.begin_crossfade() {
            tracing::warn!("crossfade_swap_failed");
            return;
        }
        // Any fade animation still running belongs to the past transition.
        let my_epoch = self.fade_epoch.fetch_add(1, Ordering::SeqCst) + 1;
        self.crossfade_active.store(true, Ordering::SeqCst);
        self.spawn_crossfade_ramp(out_ms, in_ms, my_epoch);

        tracing::info!(track_id = %track.id, out_ms, in_ms, "crossfade started");
        self.finish_promotion(track);
    }

    /// Animates both faders, each over its own window (the outgoing fade-out
    /// region and the incoming fade-in region may differ): 20 ms steps — small
    /// enough to be click-free, cheap enough to be noise. Superseded by a
    /// stop, a hard swap or another crossfade through the fade epoch.
    fn spawn_crossfade_ramp(&self, out_ms: u64, in_ms: u64, my_epoch: u64) {
        let engine = self.engine.clone();
        let generation = self.playback_generation.clone();
        let my_generation = self.playback_generation.load(Ordering::SeqCst);
        let epoch = self.fade_epoch.clone();
        let active = self.crossfade_active.clone();
        tokio::spawn(async move {
            let out_duration = std::time::Duration::from_millis(out_ms.max(1));
            let in_duration = std::time::Duration::from_millis(in_ms.max(1));
            let start = std::time::Instant::now();
            loop {
                let elapsed = start.elapsed().as_secs_f64();
                if generation.load(Ordering::SeqCst) != my_generation
                    || epoch.load(Ordering::SeqCst) != my_epoch
                {
                    return;
                }
                let t_out = (elapsed / out_duration.as_secs_f64()).clamp(0.0, 1.0);
                let t_in = (elapsed / in_duration.as_secs_f64()).clamp(0.0, 1.0);
                engine.set_fade(t_in as f32, 1.0 - t_out as f32);
                if t_out >= 1.0 && t_in >= 1.0 {
                    engine.finish_crossfade();
                    active.store(false, Ordering::SeqCst);
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        });
    }

    /// Whether a crossfade may start right now: enabled in the settings and
    /// no transition already in flight (the preheat check is on the caller).
    pub fn can_begin_crossfade(&self) -> bool {
        self.signals.crossfade_ms.get() > 0 && self.crossfade_ready_to_start()
    }

    /// No crossfade transition currently in flight.
    pub fn crossfade_ready_to_start(&self) -> bool {
        !self.crossfade_active.load(Ordering::SeqCst)
    }

    /// Server-driven overlap window (ms) of the current track's fade-out
    /// region; 0 when the track carries no usable region (the user setting
    /// applies instead).
    pub fn crossfade_out_window_ms(&self) -> u64 {
        self.crossfade_out_window_ms.load(Ordering::SeqCst)
    }

    /// Refreshes the server-driven window after the current track changes.
    fn update_crossfade_out_window(&self, track: &Track) {
        let window = match (track.fade.as_ref(), track.duration) {
            (Some(fade), Some(duration)) => {
                server_fade_out_window_ms(fade, duration.as_millis() as u64).unwrap_or(0)
            }
            _ => 0,
        };
        self.crossfade_out_window_ms.store(window, Ordering::SeqCst);
    }

    /// Marker set by the `BeginCrossfade` handler so the unified advance path
    /// promotes with an overlap instead of a hard swap.
    pub fn request_crossfade(&self) {
        self.crossfade_requested.store(true, Ordering::SeqCst);
    }

    pub fn clear_crossfade_request(&self) {
        self.crossfade_requested.store(false, Ordering::SeqCst);
    }

    pub fn take_crossfade_request(&self) -> bool {
        self.crossfade_requested.swap(false, Ordering::SeqCst)
    }

    /// Discards the parked preheat (engine slot + metadata) without touching
    /// the current playback.
    pub fn drop_preheat(&self) {
        self.preheat.lock().take();
        self.engine.drop_preheat();
    }

    pub(crate) async fn play_track(
        &self,
        track: Track,
        start_paused: bool,
        start_pos: std::time::Duration,
        soft_reload: bool,
    ) {
        if !soft_reload {
            // Tear down without publishing a stopped state, then publish the
            // incoming track below in one step. `stop()` used to run here and
            // briefly reported "no current track": consumers saw the switch as
            // a stop (covers snapped instead of sliding, the notification
            // flickered) depending on whether the bridge worker happened to
            // read the signals in that window.
            self.teardown_playback().await;
        } else {
            // Only stop current task and clear engine, without resetting UI signals.
            // No generation bump here: the single claim below invalidates the
            // aborted task and identifies this call in one step.
            let mut task_guard = self.current_playback_task.lock().await;
            if let Some(task) = task_guard.take() {
                task.abort();
            }
            self.engine.stop();
        }

        // Claim this play_track call as the sole authority over the engine going forward.
        // Any previously spawned task (even one that already ran past its last .await and
        // so ignored task.abort()) will see a mismatch and bail out before touching the engine.
        let my_generation = self.playback_generation.fetch_add(1, Ordering::SeqCst) + 1;

        self.signals.set_buffering(true);

        if !soft_reload {
            self.stream_error_retries.store(0, Ordering::SeqCst);
            self.reload_in_flight.store(0, Ordering::SeqCst);
            self.pause_requested.store(false, Ordering::SeqCst);
            // Same switch state `stop()` used to publish, minus the empty
            // current track: buffering shows, play is paused, progress restarts.
            self.signals.set_playing(false);
            self.update_crossfade_out_window(&track);
            self.signals.set_current_track(Some(track.clone()));
            self.signals
                .update_progress(0, self.signals.duration_ms.get());
            self.signals.update_buffered_ratio(0.0);
        }

        let engine = self.engine.clone();
        let stream_manager = self.stream_manager.clone();
        let progress_clock = self.progress_clock.clone();
        let progress_source = self.progress_source.clone();
        let error_sink = self.error_sink.clone();
        let signals = self.signals.clone();
        let track_clone = track.clone();
        let monitor = self.signals.monitor.clone();
        let effect_handles_store = self.effect_handles.clone();
        let reload_in_flight = self.reload_in_flight.clone();
        let stream_error_retries = self.stream_error_retries.clone();
        let tx = self.tx.clone();

        self.apply_volume();

        let generation = self.playback_generation.clone();
        let pause_requested = self.pause_requested.clone();
        let task = tokio::spawn(async move {
            match stream_manager.create_stream_session(&track_clone).await {
                Ok(prepared) => {
                    // A newer play_track()/stop() call landed while we were awaiting the
                    // stream session. task.abort() can no longer cancel us at this point, so
                    // check explicitly and abandon before touching the engine or any signal.
                    if generation.load(Ordering::SeqCst) != my_generation {
                        return;
                    }

                    reload_in_flight.store(0, Ordering::SeqCst);

                    let PreparedStream {
                        session,
                        progress: new_progress,
                        buffering,
                        ..
                    } = prepared;

                    let source = build_fx_source(session.source, &track_clone, &monitor);

                    // Migrate user-tunable FX state old -> new. UI writers take
                    // only the registry read lock + atomic set_param, so a write
                    // lock can't exclude them; snapshot-then-verify via
                    // version() closes the lost-update window instead. New
                    // handles are still task-private here.
                    let pending_handles = source.get_effect_handles();
                    let mut migrated =
                        snapshot_fx_migrations(&effect_handles_store, &pending_handles);

                    // Re-check right before the first engine mutation: building the source
                    // above takes long enough for a concurrent play_track()/stop() to have
                    // superseded us since the check above. Everything before this point is
                    // local to this task, so a superseded task bails without having written
                    // any shared state (progress/effect_handles_store) that a newer task may
                    // have already installed.
                    if generation.load(Ordering::SeqCst) != my_generation {
                        return;
                    }

                    // Publish into the stable clock (never swapped): reset, seed
                    // stream counters, remember the stream-written source for
                    // the monitor mirror. The compat wrapper keeps pointing
                    // at the same clock instance.
                    progress_clock.reset();
                    progress_clock.sync_stream_state(&new_progress);
                    *progress_source.lock() = Some(new_progress);
                    {
                        let mut store = effect_handles_store.write();
                        *store = pending_handles;
                    }

                    // Re-verify: a UI write that landed on an old handle
                    // between our snapshot and the publish is re-applied to
                    // the now-visible new handle. Bounded: only already
                    // in-flight UI calls can still target old handles.
                    for _ in 0..4 {
                        if generation.load(Ordering::SeqCst) != my_generation {
                            break;
                        }
                        if reapply_fx_migrations(&mut migrated) {
                            break;
                        }
                    }

                    // From here on this session is the one being played, so let it drive
                    // the buffering signal — prewarmed sessions are built disarmed and
                    // would otherwise stay mute, hiding every mid-track stall (and with
                    // it the 15s watchdog above) on auto-advanced tracks.
                    {
                        let signals = signals.clone();
                        let generation = generation.clone();
                        buffering.arm(std::sync::Arc::new(move |is_buffering| {
                            // The data source of a superseded session can outlive it by a
                            // moment; its stalls must not leak onto the track that replaced it.
                            if generation.load(Ordering::SeqCst) == my_generation {
                                signals.set_buffering(is_buffering);
                            }
                        }));
                    }

                    engine.play_source(source);

                    if start_pos.as_millis() > 0 {
                        let _ = engine.try_seek(start_pos);
                        progress_clock.set_current_position(start_pos);
                    }

                    tracing::info!(
                        track_id = %track_clone.id,
                        title = ?track_clone.title,
                        reload = soft_reload,
                        resume_from_ms = start_pos.as_millis() as u64,
                        "track_started"
                    );

                    signals.set_buffering(false);

                    // Pausing while the stream was still being prepared must not
                    // be undone by the session landing ready a moment later.
                    if start_paused || pause_requested.load(Ordering::SeqCst) {
                        engine.pause();
                        signals.set_playing(false);
                    } else {
                        engine.play();
                        signals.set_playing(true);
                    }
                }
                Err(e) => {
                    if stream_error_retries.load(Ordering::SeqCst) < 2
                        && reload_in_flight
                            .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
                            .is_ok()
                    {
                        stream_error_retries.fetch_add(1, Ordering::SeqCst);
                        signals.set_buffering(true);
                        if !start_paused && !pause_requested.load(Ordering::SeqCst) {
                            signals.set_playing(true);
                        }
                        if tx.try_send(AudioMessage::ReloadCurrentTrack).is_err() {
                            reload_in_flight.store(0, Ordering::SeqCst);
                            signals.set_buffering(false);
                        }
                        return;
                    }

                    // Release the reload gate: it is only cleared on success,
                    // so a failed reload would otherwise block all future
                    // recovery attempts forever.
                    reload_in_flight.store(0, Ordering::SeqCst);
                    tracing::error!(error = ?e, "create_stream_session_failed");
                    signals.set_buffering(false);
                    signals.set_playing(false);
                    signals.is_stopped.set(true);
                    error_sink(format!("Failed to play track: {}", e));
                }
            }
        });

        let mut task_guard = self.current_playback_task.lock().await;
        *task_guard = Some(task);
    }

    /// Tears the current playback down without publishing a "stopped" state.
    /// The caller owns the signal writes that follow, so a track switch can
    /// publish the incoming track directly instead of looking like a stop.
    async fn teardown_playback(&self) {
        let mut task_guard = self.current_playback_task.lock().await;
        if let Some(task) = task_guard.take() {
            task.abort();
        }
        self.playback_generation.fetch_add(1, Ordering::SeqCst);
        self.crossfade_active.store(false, Ordering::SeqCst);
        self.fade_epoch.fetch_add(1, Ordering::SeqCst);
        self.drop_preheat();
        self.engine.stop();
        self.progress_clock.reset();
        *self.progress_source.lock() = None;
    }

    pub(crate) async fn stop(&self) {
        self.teardown_playback().await;

        self.signals.set_playing(false);
        self.signals.set_current_track(None);
        self.signals.is_stopped.set(true);
        self.signals.set_buffering(false);
        self.signals.update_progress(0, 0);
        self.signals.update_buffered_ratio(0.0);
    }

    pub(crate) async fn pause(&self) {
        self.pause_requested.store(true, Ordering::SeqCst);
        self.engine.pause();
        self.signals.set_playing(false);
    }

    pub(crate) async fn resume(&self) {
        if self.engine.is_empty() && self.signals.current_track.get().is_none() {
            return;
        }
        self.pause_requested.store(false, Ordering::SeqCst);
        self.engine.play();
        self.signals.set_playing(true);
    }

    pub(crate) async fn seek(&self, pos: std::time::Duration) {
        if self.engine.try_seek(pos).is_err() {
            // Unsupported seek: keep UI and engine in sync at zero instead of
            // showing `pos` while audio restarts from the beginning.
            self.progress_clock
                .set_current_position(std::time::Duration::ZERO);
            self.signals
                .update_progress(0, self.signals.duration_ms.get());
        } else {
            self.progress_clock.set_current_position(pos);
            // Emit immediately so the UI reflects the new position even while
            // paused (the monitor loop only publishes progress during playback).
            self.signals
                .update_progress(pos.as_millis() as u64, self.signals.duration_ms.get());
        }
    }

    pub fn get_effect_handles(&self) -> Arc<RwLock<HashMap<String, EffectHandle>>> {
        self.effect_handles.clone()
    }

    pub fn set_volume(&self, volume: f32) {
        let vol_u8 = (volume * 100.0).round().clamp(0.0, 100.0) as u8;
        self.signals.set_volume(vol_u8, false);
        self.apply_volume();
    }

    pub fn set_transient_volume_gain(&self, gain: u8) {
        self.transient_volume_gain
            .store(gain.min(100), Ordering::Relaxed);
        self.apply_volume();
    }

    pub fn toggle_mute(&self) {
        let muted = self.signals.is_muted.get();
        let vol = self.signals.volume.get();
        self.signals.set_volume(vol, !muted);
        self.apply_volume();
    }

    fn apply_volume(&self) {
        let muted = self.signals.is_muted.get();
        let volume = if muted {
            0.0
        } else {
            let user_volume = self.signals.volume.get() as f32 / 100.0;
            let transient_gain = self.transient_volume_gain.load(Ordering::Relaxed) as f32 / 100.0;
            user_volume * transient_gain
        };
        self.engine.set_volume(volume);
    }
}

/// Builds the FX chain for a prepared session's source: the amplitude monitor
/// tap, the track's own fade regions, and the user-tunable effect set. Shared
/// by the play_track and gapless-preheat paths so both feed the engine
/// identically.
fn build_fx_source(
    session_source: crate::stream::BufferedStreamingSource,
    track: &Track,
    monitor: &Arc<Monitor>,
) -> FxSource<crate::stream::BufferedStreamingSource> {
    let mut source = FxSource::new(session_source);

    let monitor_params = Arc::new(EffectParams::new(&[]));
    monitor_params.set_enabled(true);
    source.add_effect(
        "monitor",
        "Audio Monitor",
        Box::new(MonitorEffect::new(
            monitor.clone(),
            source.sample_rate().get() as f32,
        )),
        monitor_params,
    );

    if let Some(fade) = track.fade.clone() {
        let fade_params = Arc::new(EffectParams::new(&[]));
        fade_params.set_enabled(true);
        source.add_effect(
            "fade",
            "Fade",
            Box::new(FadeEffect::new(
                fade.in_start,
                fade.in_stop,
                fade.out_start,
                fade.out_stop,
                source.sample_rate().get(),
                source.channels().get(),
            )),
            fade_params,
        );
    }

    crate::audio::fx::init::init_all(&mut source);
    source
}

/// Copies the outgoing track's user-FX state onto the incoming handles without
/// publishing them. The caller publishes at activation time and re-verifies
/// with `reapply_fx_migrations` to close the lost-update window.
fn snapshot_fx_migrations(
    store: &Arc<RwLock<HashMap<String, EffectHandle>>>,
    pending_handles: &HashMap<String, EffectHandle>,
) -> Vec<FxMigration> {
    let old_store = store.read();
    let mut migrated = Vec::new();
    for (name, new_handle) in pending_handles.iter() {
        if let Some(old_handle) = old_store.get(name) {
            let enabled = old_handle.is_enabled();
            new_handle.set_enabled(enabled);
            let applied = copy_fx_params(old_handle, new_handle);
            migrated.push(FxMigration {
                old: old_handle.clone(),
                new: new_handle.clone(),
                applied,
                enabled,
            });
        }
    }
    migrated
}

/// Re-syncs migrated handles with UI writes that landed since the snapshot.
/// Returns `true` when everything was already stable.
fn reapply_fx_migrations(migrated: &mut [FxMigration]) -> bool {
    let mut stable = true;
    for migration in migrated.iter_mut() {
        let cur_enabled = migration.old.is_enabled();
        if migration.new.is_enabled() != cur_enabled {
            migration.new.set_enabled(cur_enabled);
            migration.enabled = cur_enabled;
            stable = false;
        }
        let (_, current) = migration.old.snapshot();
        let n = current.len().min(migration.new.param_count());
        if current[..n] != migration.applied[..] {
            for (i, &val) in current[..n].iter().enumerate() {
                migration.new.set_param(i, val);
            }
            migration.applied = current[..n].to_vec();
            stable = false;
        }
    }
    stable
}

/// Copy FX params old -> new, returning values written. Versioned snapshot
/// when arities match, plain prefix copy otherwise (new handle is private).
fn copy_fx_params(old: &EffectHandle, new: &EffectHandle) -> Vec<f32> {
    let (_, old_values) = old.snapshot();
    let n = old_values.len().min(new.param_count());
    let (new_version, _) = new.snapshot();
    if old_values.len() == new.param_count() && new.apply_snapshot(new_version, &old_values) {
        return old_values;
    }
    for (i, &val) in old_values[..n].iter().enumerate() {
        new.set_param(i, val);
    }
    old_values[..n].to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fade(in_start: f32, in_stop: f32, out_start: f32, out_stop: f32) -> TrackFade {
        TrackFade {
            in_start,
            in_stop,
            out_start,
            out_stop,
        }
    }

    #[test]
    fn server_fade_out_window_spans_region_to_track_end() {
        // Fade-out region 210 s → 213 s on a 213 s track: a 3 s overlap.
        let f = fade(0.0, 0.0, 210.0, 213.0);
        assert_eq!(server_fade_out_window_ms(&f, 213_000), Some(3_000));
    }

    #[test]
    fn server_fade_out_window_rejects_degenerate_regions() {
        assert_eq!(
            server_fade_out_window_ms(&fade(0.0, 0.0, 0.0, 5.0), 213_000),
            None,
            "out_start at the very beginning is not a fade-out region"
        );
        assert_eq!(
            server_fade_out_window_ms(&fade(0.0, 0.0, 300.0, 310.0), 213_000),
            None,
            "region past the track end"
        );
        assert_eq!(
            server_fade_out_window_ms(&fade(0.0, 0.0, 100.0, 105.0), 0),
            None,
            "unknown duration"
        );
    }

    #[test]
    fn server_fade_out_window_is_capped_at_preheat_ahead() {
        // A 299 s region cannot start earlier than preheat arming allows.
        let f = fade(0.0, 0.0, 1.0, 300.0);
        assert_eq!(
            server_fade_out_window_ms(&f, 300_000),
            Some(PREHEAT_AHEAD_MS)
        );
    }

    #[test]
    fn server_fade_in_window_is_the_fade_in_length() {
        assert_eq!(
            server_fade_in_window_ms(&fade(0.0, 4.0, 200.0, 203.0)),
            Some(4_000)
        );
        assert_eq!(
            server_fade_in_window_ms(&fade(0.0, 0.0, 200.0, 203.0)),
            None,
            "no fade-in region"
        );
    }
}
