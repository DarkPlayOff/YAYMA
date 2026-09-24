use foldhash::HashMap;
use parking_lot::RwLock;
use rodio::Source;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use tokio::sync::Mutex;
use yandex_music::model::track::Track;

use crate::audio::{
    commands::AudioMessage,
    fx::{
        EffectHandle, FxSource,
        modules::{FadeEffect, MonitorEffect},
        param::EffectParams,
    },
    playback::PlaybackEngine,
    progress::TrackProgress,
    signals::AudioSignals,
    stream_manager::StreamManager,
};

pub struct AudioController {
    engine: Arc<PlaybackEngine>,
    stream_manager: Arc<StreamManager>,
    tx: tokio::sync::mpsc::Sender<AudioMessage>,
    error_sink: Arc<dyn Fn(String) + Send + Sync>,
    // Compat handle, always points at `progress_clock`, never swapped.
    pub track_progress: Arc<RwLock<Arc<TrackProgress>>>,
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
    transient_volume_gain: Arc<AtomicU8>,
    signals: AudioSignals,
    effect_handles: Arc<RwLock<HashMap<String, EffectHandle>>>,
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
            track_progress: self.track_progress.clone(),
            progress_clock: self.progress_clock.clone(),
            progress_source: self.progress_source.clone(),
            current_playback_task: self.current_playback_task.clone(),
            monitor_task: parking_lot::Mutex::new(None),
            playback_generation: self.playback_generation.clone(),
            stream_error_retries: self.stream_error_retries.clone(),
            reload_in_flight: self.reload_in_flight.clone(),
            transient_volume_gain: self.transient_volume_gain.clone(),
            signals: self.signals.clone(),
            effect_handles: self.effect_handles.clone(),
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
        track_progress: Arc<RwLock<Arc<TrackProgress>>>,
    ) -> Self {
        let effect_handles = crate::audio::fx::init::create_templates();
        // Same instance QueueManager holds (built in AudioSystem::spawn).
        let progress_clock = track_progress.read().clone();
        let controller = Self {
            engine: Arc::new(engine),
            stream_manager,
            tx,
            error_sink,
            track_progress,
            progress_clock,
            progress_source: Arc::new(parking_lot::Mutex::new(None)),
            current_playback_task: Arc::new(Mutex::new(None)),
            monitor_task: parking_lot::Mutex::new(None),
            playback_generation: Arc::new(AtomicU64::new(0)),
            stream_error_retries: Arc::new(AtomicU8::new(0)),
            reload_in_flight: Arc::new(AtomicU8::new(0)),
            transient_volume_gain: Arc::new(AtomicU8::new(100)),
            signals,
            effect_handles: Arc::new(RwLock::new(effect_handles)),
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

                    // engine.pos() is the single source of position here;
                    // position_ms (signals) and TrackProgress (clock) are mirrors of it.
                    if signals.monitor.is_focused() {
                        let pos = engine.pos();
                        let dur = signals.duration_ms.get();

                        signals.update_progress(pos.as_millis() as u64, dur);

                        progress_clock.set_current_position(pos);
                        let buffered = progress_clock.get_buffered_ratio() as f32;
                        signals.update_buffered_ratio(buffered);

                        let amp = signals.monitor.combined_amplitude();
                        signals.amplitude.set(amp);
                    } else {
                        // Keep position fresh while unfocused: Prev threshold
                        // and reload use position_ms, only heavy UI updates
                        // (amplitude/buffered) stay gated.
                        let pos = engine.pos();
                        signals.update_progress(pos.as_millis() as u64, signals.duration_ms.get());
                        progress_clock.set_current_position(pos);
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

    pub fn recreate_engine(
        &self,
        device_name: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.engine.recreate(device_name)
    }

    pub(crate) async fn play_track(
        &self,
        track: Track,
        start_paused: bool,
        start_pos: std::time::Duration,
        soft_reload: bool,
    ) {
        if !soft_reload {
            self.stop().await;
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
            self.signals.is_stopped.set(false);
            self.signals.set_current_track(Some(track.clone()));
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

                    let crate::audio::stream_manager::PreparedStream {
                        session,
                        progress: new_progress,
                        buffering,
                        ..
                    } = prepared;

                    let mut source = FxSource::new(session.source);

                    let monitor_params = Arc::new(EffectParams::new(&[]));
                    monitor_params.set_enabled(true);
                    source.add_effect(
                        "monitor",
                        "Audio Monitor",
                        Box::new(MonitorEffect::new(
                            monitor,
                            source.sample_rate().get() as f32,
                        )),
                        monitor_params,
                    );

                    if let Some(fade) = track_clone.fade.clone() {
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

                    // Migrate user-tunable FX state old -> new. UI writers take
                    // only the registry read lock + atomic set_param, so a write
                    // lock can't exclude them; snapshot-then-verify via
                    // version() closes the lost-update window instead. New
                    // handles are still task-private here.
                    let pending_handles = source.get_effect_handles();
                    let mut migrated: Vec<(EffectHandle, EffectHandle, Vec<f32>, bool)> = {
                        let old_store = effect_handles_store.read();
                        let mut migrated = Vec::new();
                        for (name, new_handle) in pending_handles.iter() {
                            if let Some(old_handle) = old_store.get(name) {
                                let enabled = old_handle.is_enabled();
                                new_handle.set_enabled(enabled);
                                let applied = copy_fx_params(old_handle, new_handle);
                                migrated.push((
                                    old_handle.clone(),
                                    new_handle.clone(),
                                    applied,
                                    enabled,
                                ));
                            }
                        }
                        migrated
                    };

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
                        let mut stable = true;
                        for (old_handle, new_handle, applied, enabled) in migrated.iter_mut() {
                            let cur_enabled = old_handle.is_enabled();
                            if new_handle.is_enabled() != cur_enabled {
                                new_handle.set_enabled(cur_enabled);
                                *enabled = cur_enabled;
                                stable = false;
                            }
                            let (_, current) = old_handle.snapshot();
                            let n = current.len().min(new_handle.param_count());
                            if current[..n] != applied[..] {
                                for (i, &val) in current[..n].iter().enumerate() {
                                    new_handle.set_param(i, val);
                                }
                                *applied = current[..n].to_vec();
                                stable = false;
                            }
                        }
                        if stable {
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
                        buffering.arm(Box::new(move |is_buffering| {
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

                    signals.set_buffering(false);

                    if start_paused {
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
                        if !start_paused {
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
                    tracing::error!("Failed to create stream session: {:?}", e);
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

    pub(crate) async fn stop(&self) {
        let mut task_guard = self.current_playback_task.lock().await;
        if let Some(task) = task_guard.take() {
            task.abort();
        }
        self.playback_generation.fetch_add(1, Ordering::SeqCst);
        self.engine.stop();
        self.progress_clock.reset();
        *self.progress_source.lock() = None;

        self.signals.set_playing(false);
        self.signals.set_current_track(None);
        self.signals.is_stopped.set(true);
        self.signals.set_buffering(false);
        self.signals.update_progress(0, 0);
        self.signals.update_buffered_ratio(0.0);
    }

    pub(crate) async fn pause(&self) {
        self.engine.pause();
        self.signals.set_playing(false);
    }

    pub(crate) async fn resume(&self) {
        if self.engine.is_empty() && self.signals.current_track.get().is_none() {
            return;
        }
        self.engine.play();
        self.signals.set_playing(true);
    }

    pub(crate) async fn seek(&self, pos: std::time::Duration) {
        if self.engine.try_seek(pos).is_err() {
            // Unsupported seek: keep UI and engine in sync at zero instead of
            // showing `pos` while audio restarts from the beginning.
            self.progress_clock.set_current_position(std::time::Duration::ZERO);
            self.signals.update_progress(0, self.signals.duration_ms.get());
        } else {
            self.progress_clock.set_current_position(pos);
        }
    }

    pub fn get_effect_handles(&self) -> Arc<RwLock<HashMap<String, EffectHandle>>> {
        self.effect_handles.clone()
    }

    pub fn set_volume(&self, volume: f32) {
        let vol_u8 = (volume * 100.0).round().clamp(0.0, 100.0) as u8;
        self.signals.set_volume(vol_u8.min(100), false);
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
