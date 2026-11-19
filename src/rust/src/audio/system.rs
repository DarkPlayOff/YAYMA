use crate::audio::cache::UrlCache;
use crate::audio::plays::{EndReason, PlayContext};
use crate::{
    audio::{
        commands::AudioMessage, controller::AudioController, fetcher::is_usable_wave_session,
        playback::PlaybackEngine, plays::PlayReporter, progress::TrackProgress,
        queue::QueueManager, queue::as_wave_seed, signals::AudioSignals, state::SystemState,
        stream_manager::StreamManager, yandex::YandexProvider,
    },
    http::{ApiService, LikedTracksSync, SessionExt},
};

#[cfg(not(any(target_os = "android")))]
use crate::audio::{discord::DiscordManager, smtc::SmtcManager};

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
#[cfg(not(any(target_os = "android")))]
use tokio::sync::Mutex;
use tokio::sync::{RwLock, mpsc};
use yandex_music::model::track::Track;

#[path = "system_loading.rs"]
mod system_loading;
#[path = "system_wave.rs"]
mod system_wave;

use system_wave::WavePostAction;

// Abort-on-Drop guard for detached SMTC tasks (polling loop has no
// other shutdown signal); explicit stop via `AudioSystem::shutdown`.
#[cfg(not(any(target_os = "android")))]
struct AbortOnDrop {
    handle: Option<tokio::task::JoinHandle<()>>,
}

#[cfg(not(any(target_os = "android")))]
impl AbortOnDrop {
    fn new(handle: tokio::task::JoinHandle<()>) -> Self {
        Self {
            handle: Some(handle),
        }
    }

    fn shutdown(&mut self) {
        if let Some(h) = self.handle.take() {
            h.abort();
        }
    }
}

#[cfg(not(any(target_os = "android")))]
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.shutdown();
    }
}

// Selects the head of the unified advance path (ended vs user skip).
// A skip carries the plays-report end reason: `skip`, or `dislike` for a
// dislike-driven skip (the desktop client distinguishes them).
#[derive(Clone, Copy, PartialEq, Eq)]
enum AdvanceReason {
    TrackEnded,
    Skipped(EndReason),
}

pub type EffectHandles =
    Arc<parking_lot::RwLock<foldhash::HashMap<String, crate::audio::fx::EffectHandle>>>;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const PREVIOUS_TRACK_RESTART_THRESHOLD: Duration = Duration::from_secs(5);

/// Stored form of the persisted repeat mode.
fn repeat_mode_key(mode: crate::audio::enums::RepeatMode) -> String {
    match mode {
        crate::audio::enums::RepeatMode::None => "none",
        crate::audio::enums::RepeatMode::All => "all",
        crate::audio::enums::RepeatMode::Single => "single",
    }
    .to_string()
}

pub struct AudioSystem {
    controller: AudioController,
    queue: QueueManager,
    yandex: YandexProvider,
    plays: PlayReporter,
    error_sink: Arc<dyn Fn(String) + Send + Sync>,
    state: Arc<RwLock<SystemState>>,
    signals: AudioSignals,
    tx: mpsc::Sender<AudioMessage>,
    db: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
    context_generation: Arc<AtomicU64>,
    #[cfg(not(any(target_os = "android")))]
    smtc_guards: Vec<AbortOnDrop>,
}

impl AudioSystem {
    pub async fn spawn(
        error_sink: Arc<dyn Fn(String) + Send + Sync>,
        api: Arc<ApiService>,
        db: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
        _http_cache: Arc<crate::storage::cache::HttpCache>,
        track_cache: Arc<crate::storage::cache::TrackCache>,
        _shutdown_rx: tokio::sync::watch::Receiver<bool>,
    ) -> Result<(
        mpsc::Sender<AudioMessage>,
        AudioSignals,
        Arc<RwLock<SystemState>>,
        EffectHandles,
    )> {
        let (tx, mut rx) = mpsc::channel(100);

        let engine = PlaybackEngine::new(tx.clone())?;
        let url_cache = UrlCache::new();
        let stream_manager = Arc::new(
            tokio::task::spawn_blocking({
                let api = api.clone();
                let url_cache = url_cache.clone();
                let track_cache = track_cache.clone();
                move || StreamManager::new(api, url_cache, track_cache)
            })
            .await
            .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))?,
        );

        let signals = AudioSignals::new();
        let track_progress_inner = Arc::new(TrackProgress::default());

        let controller = AudioController::new(
            engine,
            stream_manager.clone(),
            tx.clone(),
            error_sink.clone(),
            signals.clone(),
            track_progress_inner.clone(),
        );

        let queue = QueueManager::new(
            api.clone(),
            url_cache,
            stream_manager.clone(),
            signals.clone(),
            track_progress_inner,
        );

        let state = Arc::new(RwLock::new(SystemState::default()));

        // Load liked tracks from DB for instant start
        {
            let mut db = db.lock().await;
            if let Ok(ids) = db.load_liked_tracks().await {
                let revision: Option<u64> = db
                    .load_setting("liked_tracks_revision")
                    .await
                    .ok()
                    .flatten();
                let disliked: Vec<String> = db
                    .load_setting(crate::api::library::DISLIKED_TRACKS_KEY)
                    .await
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let mut state = state.write().await;
                state.liked.set_liked_ids(ids);
                state.liked.set_disliked_ids(disliked);
                state.liked.revision = revision;
                signals.library_changed.send_replace(());
            }
        }

        #[cfg(not(any(target_os = "android")))]
        let (smtc, smtc_cmd_rx) = {
            let (smtc_cmd_tx, smtc_cmd_rx) = mpsc::unbounded_channel();
            let smtc = Arc::new(Mutex::new(SmtcManager::new(
                smtc_cmd_tx,
                _http_cache.clone(),
                signals.current_track_id.clone(),
            )?));
            (smtc, smtc_cmd_rx)
        };

        let yandex = YandexProvider::new(api.clone(), signals.clone());

        let plays = PlayReporter::new(api.clone());

        let effect_handles = controller.get_effect_handles();

        let system = Self {
            controller,
            queue,
            yandex,
            plays,
            error_sink: error_sink.clone(),
            state: state.clone(),
            signals: signals.clone(),
            tx: tx.clone(),
            db,
            context_generation: Arc::new(AtomicU64::new(0)),
            #[cfg(not(any(target_os = "android")))]
            smtc_guards: Vec::new(),
        };

        let mut system_loop = system;

        // Start Discord integration
        #[cfg(not(any(target_os = "android")))]
        DiscordManager::spawn(signals.clone(), _shutdown_rx.clone());

        // Background task for SMTC
        #[cfg(not(any(target_os = "android")))]
        {
            let tx_clone = tx.clone();
            let mut rx_smtc = smtc_cmd_rx;
            let fwd_handle = tokio::spawn(async move {
                while let Some(msg) = rx_smtc.recv().await {
                    let _ = tx_clone.send(msg).await;
                }
            });
            system_loop.smtc_guards.push(AbortOnDrop::new(fwd_handle));
        }

        // Monitor signals to update SMTC
        #[cfg(not(any(target_os = "android")))]
        {
            let smtc_clone = smtc;
            let signals_clone = signals.clone();
            let poll_handle = tokio::spawn(async move {
                let mut last_track_id = None;
                let mut last_playing = false;

                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

                    let current_track = signals_clone.current_track.get();
                    let current_track_id = current_track.as_ref().map(|t| t.id.clone());
                    let is_playing = signals_clone.is_playing.get();

                    let mut smtc_guard: tokio::sync::MutexGuard<SmtcManager> =
                        smtc_clone.lock().await;

                    if current_track_id != last_track_id {
                        if let Some(track) = current_track {
                            smtc_guard.update_metadata(&track);
                        }
                        last_track_id = current_track_id;
                    }

                    if is_playing != last_playing {
                        smtc_guard.update_playback_status(is_playing);
                        last_playing = is_playing;
                    }
                }
            });
            system_loop.smtc_guards.push(AbortOnDrop::new(poll_handle));
        }

        // Main Audio Loop
        tokio::spawn(async move {
            // A finished wave / playlist fetch is otherwise only consumed on
            // the next track change, so the upcoming queue (and the cover
            // carousel) stays empty while the current track plays. The fetch
            // task signals completion instead of the actor polling for it.
            let fetch_finished = system_loop.queue.fetch_finished();
            // One `Notified` kept alive across iterations: recreating it each
            // loop lets `select!` discard a future that already consumed the
            // notify permit when the message branch wins, losing the wake-up.
            // Replace it only after it actually fires.
            let mut fetch_notified = Box::pin(fetch_finished.notified());
            // Coarse clock for `/plays` progress reports (one per 30 s played).
            let mut report_tick = tokio::time::interval(std::time::Duration::from_secs(5));
            report_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    msg = rx.recv() => {
                        let Some(msg) = msg else { break };
                        if matches!(msg, AudioMessage::Shutdown) {
                            // Only way out of this loop: the actor holds one
                            // of the channel's senders itself, so `recv()`
                            // never yields `None`. Breaking here lets the
                            // post-loop teardown below finally run.
                            break;
                        }
                        if matches!(msg, AudioMessage::Next) {
                            // Skip-burst debounce: collapse already-queued
                            // Next presses into a single advance without
                            // waiting. A non-Next message drained first is
                            // processed right after.
                            let mut pending_other = None;
                            while let Ok(extra) = rx.try_recv() {
                                if matches!(extra, AudioMessage::Next) {
                                    continue;
                                }
                                pending_other = Some(extra);
                                break;
                            }
                            system_loop.process_message(msg).await;
                            if let Some(other) = pending_other {
                                system_loop.process_message(other).await;
                            }
                        } else {
                            system_loop.process_message(msg).await;
                        }
                    }
                    _ = fetch_notified.as_mut() => {
                        fetch_notified = Box::pin(fetch_finished.notified());
                        // Refill from the buffer. Only request another page
                        // when nothing is visible ahead: a page landed means
                        // the carousel has tracks, and a short page must not
                        // turn into a continuous fetch chain.
                        let grew = system_loop.queue.poll_fetch();
                        let nothing_ahead = system_loop.queue.has_no_visible_next();
                        system_loop.queue.refill_wave_window(grew && nothing_ahead);
                    }
                    _ = report_tick.tick() => {
                        let playing = system_loop.signals.is_playing.get();
                        let position = std::time::Duration::from_millis(
                            system_loop.signals.position_ms.get(),
                        );
                        system_loop.plays.tick(playing, position);
                    }
                }
            }
            // Close the active listen so teardown (e.g. re-login) mid-track
            // doesn't leave a dangling play server-side.
            system_loop.report_track_end(EndReason::OtherTrack);
            system_loop.shutdown().await;
        });

        Ok((tx, signals, state, effect_handles))
    }

    /// Universal spawn for loading playback context
    fn begin_context_change(&self) -> u64 {
        self.context_generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1)
    }

    fn spawn_fetch_context<F, Fut>(&self, generation: u64, fetcher: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<
                Output = std::result::Result<
                    (
                        crate::audio::queue::PlaybackContext,
                        im::Vector<yandex_music::model::track::Track>,
                        usize,
                    ),
                    String,
                >,
            > + Send
            + 'static,
    {
        let tx = self.tx.clone();
        self.signals.set_buffering(true);
        tokio::spawn(async move {
            let result = fetcher().await;
            let _ = tx
                .send(AudioMessage::ContextFetched { generation, result })
                .await;
        });
    }

    pub fn get_effect_handles(&self) -> EffectHandles {
        self.controller.get_effect_handles()
    }

    // Explicit stop for background tasks: SMTC loops plus the controller
    // monitor loop and in-flight playback task. Idempotent; Drop guards
    // abort the same tasks as a backstop. Call on context teardown
    // (e.g. re-login spawns a fresh AudioSystem in-process).
    pub async fn shutdown(&mut self) {
        #[cfg(not(any(target_os = "android")))]
        for g in &mut self.smtc_guards {
            g.shutdown();
        }
        self.controller.shutdown().await;
    }

    // Unified offline-backed single-track spawn; `source` selects the
    // album/playlist/liked remote branch (resolver lives in system_loading).
    fn spawn_single_track_with_offline(
        &self,
        source: system_loading::SingleTrackSource,
        tid: String,
    ) {
        // Offline check + DB read run in background so the actor stays
        // responsive to Pause/Seek/Next while they complete.
        let generation = self.begin_context_change();
        let tx = self.tx.clone();
        let stream_manager = self.queue.stream_manager.clone();
        let db = self.db.clone();
        let yandex = self.yandex.clone();
        let state = match &source {
            system_loading::SingleTrackSource::Liked => Some(self.state.clone()),
            _ => None,
        };
        tokio::spawn(async move {
            system_loading::resolve_single_track_offline_or_remote(
                source,
                tid,
                stream_manager,
                db,
                state,
                yandex,
                tx,
                generation,
            )
            .await;
        });
    }

    async fn load_context(
        &mut self,
        ctx: crate::audio::queue::PlaybackContext,
        tracks: im::Vector<Track>,
        index: usize,
    ) {
        self.load_context_inner(None, ctx, tracks, index).await;
    }

    /// Desktop getPlayContextRequestKey parity: clicking a track that belongs
    /// to the context already playing must not rebuild the queue — it jumps
    /// to that position instead, preserving shuffle, wave state and queue
    /// edits. Returns false when the context differs (or the track is not in
    /// the queue) so the caller falls back to the rebuild.
    async fn try_jump_within_context(
        &mut self,
        source: &system_loading::SingleTrackSource,
        tid: &str,
    ) -> bool {
        let matched = self.queue.with_playback_context(|ctx| match (ctx, source) {
            (
                crate::audio::queue::PlaybackContext::Album(album),
                system_loading::SingleTrackSource::AlbumTrack { album_id },
            ) => album.id == Some(*album_id),
            (
                crate::audio::queue::PlaybackContext::Playlist(playlist),
                system_loading::SingleTrackSource::PlaylistTrack { kind },
            ) => playlist.kind == *kind,
            // Liked tracks play through the private playlist kind 3.
            (
                crate::audio::queue::PlaybackContext::Playlist(playlist),
                system_loading::SingleTrackSource::Liked,
            ) => playlist.kind == 3,
            _ => false,
        });
        if !matched {
            return false;
        }
        let position = self
            .signals
            .queue
            .with(|q| q.iter().position(|t| t.id == tid));
        match position {
            Some(index) => {
                self.play_queue_index(index).await;
                true
            }
            None => false,
        }
    }

    /// Queue-position jump (user tap on a queue row or an idempotent
    /// context re-click): starts the target track through the same
    /// preheat-or-play path the unified advance uses.
    async fn play_queue_index(&mut self, index: usize) {
        let Some(track) = self.queue.jump_to(index) else {
            return;
        };
        self.report_track_end(EndReason::Skip);
        if self.queue.in_wave() {
            self.send_wave_track_started(&track);
        }
        if self.controller.can_activate_preheat(&track.id) {
            self.controller.activate_preheat(track.clone());
        } else {
            self.controller
                .play_track(track.clone(), false, Duration::ZERO, false)
                .await;
        }
        self.report_track_start(&track, Duration::ZERO, false);
    }

    /// Fire-and-forget settings write; the actor never waits on the DB.
    fn persist_setting<T: serde::Serialize + Clone + Send + Sync + 'static>(
        &self,
        key: &str,
        value: &T,
    ) {
        let db = self.db.clone();
        let key = key.to_string();
        let value = value.clone();
        tokio::spawn(async move {
            let mut db = db.lock().await;
            if let Err(e) = db.save_setting(&key, &value).await {
                tracing::error!(error = ?e, key = %key, "persist_setting_failed");
            }
        });
    }

    async fn load_fetched_context(
        &mut self,
        generation: u64,
        ctx: crate::audio::queue::PlaybackContext,
        tracks: im::Vector<Track>,
        index: usize,
    ) {
        self.load_context_inner(Some(generation), ctx, tracks, index)
            .await;
    }

    // Single loader; `Some(generation)` enables the fetched-path
    // generation guard (entry + right before applying state).
    async fn load_context_inner(
        &mut self,
        generation: Option<u64>,
        ctx: crate::audio::queue::PlaybackContext,
        tracks: im::Vector<Track>,
        index: usize,
    ) {
        if let Some(g) = generation
            && self.context_generation.load(Ordering::Acquire) != g
        {
            return;
        }

        let in_wave = matches!(&ctx, crate::audio::queue::PlaybackContext::Wave(_));
        if let Some(track) = self.queue.load(ctx, tracks, index).await {
            // Keep the check in the actor immediately before applying the loaded
            // queue/controller state. ContextFetched messages are the only path
            // where a background fetch can reach playback.
            if let Some(g) = generation
                && self.context_generation.load(Ordering::Acquire) != g
            {
                return;
            }

            if in_wave {
                self.send_wave_started();
            }
            self.controller
                .play_track(track.clone(), false, Duration::ZERO, false)
                .await;
            if in_wave {
                self.send_wave_track_started(&track);
            }
            self.report_track_start(&track, Duration::ZERO, false);
        }
    }

    async fn load_standalone(
        &mut self,
        tracks: im::Vector<Track>,
        start_paused: bool,
        position: Duration,
    ) {
        if let Some(track) = self
            .queue
            .load(crate::audio::queue::PlaybackContext::Standalone, tracks, 0)
            .await
        {
            self.controller
                .play_track(track.clone(), start_paused, position, false)
                .await;
            self.report_track_start(&track, position, start_paused);
        }
    }

    async fn recreate_stream(&mut self) {
        let device = self.signals.selected_device.get();
        if let Err(e) = self.controller.recreate_engine(device.as_deref()).await {
            // The old stream keeps running (recreate swaps state only after
            // the new device opens), so the user must hear about the failure
            // instead of wondering why nothing changed.
            tracing::error!(error = %e, "recreate_stream_failed");
            (self.error_sink)(format!("Failed to recreate audio stream: {e}"));
        } else {
            self.reload_track().await;
        }
    }

    async fn reload_track(&mut self) {
        if let Some(track) = self.signals.current_track.get() {
            let position_ms = self.signals.position_ms.get();
            self.signals.set_buffering(true);
            self.controller.invalidate_track(&track.id);
            self.controller.replace_track(track, position_ms).await;
        }
    }

    async fn process_message(&mut self, msg: AudioMessage) {
        match msg {
            AudioMessage::ContextFetched { generation, result } => match result {
                Ok((ctx, tracks, index)) => {
                    self.load_fetched_context(generation, ctx, tracks, index)
                        .await;
                }
                Err(e) => {
                    if self.context_generation.load(Ordering::Acquire) != generation {
                        return;
                    }
                    (self.error_sink)(e);
                    self.signals.set_buffering(false);
                }
            },
            AudioMessage::PlayPause => {
                if self.signals.is_playing.get() {
                    self.report_pause();
                    self.controller.pause().await;
                } else {
                    self.report_resume();
                    self.controller.resume().await;
                }
            }
            AudioMessage::Pause => {
                self.report_pause();
                self.controller.pause().await;
            }
            AudioMessage::Resume => {
                self.report_resume();
                self.controller.resume().await;
            }
            AudioMessage::Stop => {
                self.report_track_end(EndReason::OtherTrack);
                self.begin_context_change();
                self.controller.stop().await;
                self.queue.clear();
            }
            AudioMessage::Next => {
                self.play_next().await;
            }
            AudioMessage::Prev => {
                if self.signals.position_ms.get()
                    > PREVIOUS_TRACK_RESTART_THRESHOLD.as_millis() as u64
                {
                    self.plays.seek();
                    self.controller.seek(Duration::ZERO).await;
                    self.signals
                        .update_progress(0, self.signals.duration_ms.get());
                } else if let Some(prev_track) = self.queue.get_previous_track() {
                    self.report_track_end(EndReason::BackSkip);
                    self.controller
                        .play_track(prev_track.clone(), false, Duration::ZERO, false)
                        .await;
                    self.report_track_start(&prev_track, Duration::ZERO, false);
                }
            }
            AudioMessage::PreviousTrack => {
                if let Some(prev_track) = self.queue.get_previous_track() {
                    self.report_track_end(EndReason::BackSkip);
                    self.controller
                        .play_track(prev_track.clone(), false, Duration::ZERO, false)
                        .await;
                    self.report_track_start(&prev_track, Duration::ZERO, false);
                }
            }
            AudioMessage::TrackEnded => {
                self.on_track_ended().await;
            }
            AudioMessage::PreheatNext => {
                // Re-peeking keeps a stale request after a skip or queue edit
                // harmless; arming is idempotent and never blocks.
                if let Some(next) = self.queue.peek_gapless_next() {
                    self.controller.preheat_next(next);
                }
            }
            AudioMessage::BoundaryCrossed => {
                // The boundary watch thread fired at the sample-accurate end of
                // the current source. A live firing arrives with the preheat
                // still parked and the engine drained; claiming buffering first
                // silences the monitor's empty-poll TrackEnded fallback for the
                // rest of the advance (the swap clears it, play_track sets its
                // own claim, the wave fetch keeps it). Stale firings — player
                // stopped early by a skip/seek — see a non-empty engine or no
                // preheat and are ignored here.
                if self.controller.has_preheat() && self.controller.engine_is_empty() {
                    let position_ms = self.signals.position_ms.get() as u128;
                    let duration_ms = self.signals.duration_ms.get() as u128;
                    let ended_early =
                        duration_ms > 0 && position_ms.saturating_add(1_000) < duration_ms;
                    if !ended_early {
                        // Claim buffering for the whole advance: the queue
                        // step may await a wave page fetch longer than the
                        // monitor's swap grace, and a poll-fired TrackEnded
                        // landing mid-advance would double-advance.
                        self.signals.set_buffering(true);
                        self.advance_queue(AdvanceReason::TrackEnded).await;
                        return;
                    }
                    // The stream truncated mid-track with a preheat parked:
                    // the ended-early reload path owns recovery, hand the
                    // boundary over to it (play_track's stop drops the slot).
                    self.controller.drop_preheat();
                }
            }
            AudioMessage::Seek(dur, track_id) => {
                // The id was captured at send time; a seek that raced an
                // auto-advance or Next must not land on the new track.
                if let Some(id) = track_id
                    && self
                        .signals
                        .current_track_id
                        .with(|cur| cur.as_deref() != Some(id.as_str()))
                {
                    tracing::debug!(track_id = %id, "seek_dropped_stale_track");
                    return;
                }
                tracing::debug!(position_ms = dur.as_millis() as u64, "seek");
                self.plays.seek();
                self.controller.seek(dur).await;
            }
            AudioMessage::SetVolume(vol) => self.controller.set_volume(vol as f32 / 100.0),
            AudioMessage::SetTransientVolumeGain(gain) => {
                self.controller.set_transient_volume_gain(gain)
            }
            AudioMessage::ToggleMute => self.controller.toggle_mute(),

            AudioMessage::PlayTrack(track) => {
                self.begin_context_change();
                self.load_standalone(im::Vector::from(vec![track]), false, Duration::ZERO)
                    .await
            }
            AudioMessage::RestoreTrack(track, pos, was_playing) => {
                self.begin_context_change();
                self.load_standalone(im::Vector::from(vec![track]), !was_playing, pos)
                    .await
            }
            AudioMessage::LoadContext(ctx, tracks, index) => {
                self.begin_context_change();
                self.load_context(ctx, tracks, index).await;
            }
            AudioMessage::LoadTracks(tracks) => {
                self.begin_context_change();
                self.load_standalone(im::Vector::from(tracks), false, Duration::ZERO)
                    .await
            }
            AudioMessage::QueueTrack(track) => self.queue.queue_track(track),
            AudioMessage::PlayTrackNext(track) => self.queue.play_next(track),
            AudioMessage::RemoveFromQueue(idx) => self.queue.remove_track(idx),
            AudioMessage::ClearQueue => self.queue.clear(),
            AudioMessage::ReorderQueue(from, to) => self.queue.reorder(from, to),
            AudioMessage::PlayQueueIndex(index) => self.play_queue_index(index).await,
            // The wave queue is owned by the rotor session: shuffle/repeat
            // would desync it from the server-side track stream, so both are
            // disabled in a wave context (desktop-client parity).
            AudioMessage::SetRepeatMode(mode) => {
                if !self.queue.in_wave() {
                    self.queue.set_repeat_mode(mode);
                    self.persist_setting("repeat_mode", &repeat_mode_key(mode));
                }
            }
            AudioMessage::SetShuffle(enabled) => {
                if !self.queue.in_wave() {
                    self.queue.set_shuffle(enabled);
                    self.persist_setting("shuffle_enabled", &enabled);
                }
            }
            AudioMessage::ToggleShuffle => {
                if !self.queue.in_wave() {
                    let enabled = self.queue.toggle_shuffle();
                    self.persist_setting("shuffle_enabled", &enabled);
                }
            }
            AudioMessage::ToggleRepeatMode => {
                if !self.queue.in_wave() {
                    let mode = self.queue.toggle_repeat_mode();
                    self.persist_setting("repeat_mode", &repeat_mode_key(mode));
                }
            }

            AudioMessage::PlayPlaylist(kind) => {
                let generation = self.begin_context_change();
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(generation, move || async move {
                    yandex
                        .fetch_playlist_context(kind, None)
                        .await
                        .map_err(|e| format!("Failed to load playlist: {e}"))
                });
            }
            AudioMessage::PlayAlbum(album_id) => {
                let generation = self.begin_context_change();
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(generation, move || async move {
                    yandex
                        .fetch_album_context(album_id, None)
                        .await
                        .map_err(|e| format!("Failed to load album: {e}"))
                });
            }
            AudioMessage::PlayAlbumTrack(aid, tid) => {
                if self
                    .try_jump_within_context(
                        &system_loading::SingleTrackSource::AlbumTrack { album_id: aid },
                        &tid,
                    )
                    .await
                {
                    return;
                }
                self.spawn_single_track_with_offline(
                    system_loading::SingleTrackSource::AlbumTrack { album_id: aid },
                    tid,
                );
            }
            AudioMessage::PlayPlaylistTrack(kind, tid) => {
                if self
                    .try_jump_within_context(
                        &system_loading::SingleTrackSource::PlaylistTrack { kind },
                        &tid,
                    )
                    .await
                {
                    return;
                }
                self.spawn_single_track_with_offline(
                    system_loading::SingleTrackSource::PlaylistTrack { kind },
                    tid,
                );
            }
            AudioMessage::PlayLikedTrack(tid) => {
                if self
                    .try_jump_within_context(&system_loading::SingleTrackSource::Liked, &tid)
                    .await
                {
                    return;
                }
                self.spawn_single_track_with_offline(system_loading::SingleTrackSource::Liked, tid);
            }
            AudioMessage::StartWave(seeds) => {
                tracing::info!(seeds = seeds.len(), "wave_session_started");
                let generation = self.begin_context_change();
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(generation, move || async move {
                    yandex
                        .fetch_wave_context(seeds)
                        .await
                        .map_err(|e| format!("Failed to start wave: {e}"))
                });
            }
            AudioMessage::SyncLiked => {
                Self::sync_liked_collection_with(
                    self.yandex.api.clone(),
                    self.state.clone(),
                    self.signals.clone(),
                    self.db.clone(),
                )
                .await;
                self.signals.changed.send_replace(());
            }
            AudioMessage::WaveLike(track_id) => {
                if self.queue.in_wave() {
                    let current = self.signals.current_track.get();
                    if current.as_ref().map(|t| t.id.as_str()) == Some(&track_id) {
                        if let Some(track) = current {
                            self.send_wave_like(&track);
                        }
                    } else {
                        let batch = self.queue.wave_batch_for_id(&track_id);
                        self.send_wave_feedback("like", Some(track_id), batch, None);
                    }
                }
            }
            AudioMessage::WaveUnlike(track_id) => {
                if self.queue.in_wave() {
                    let current = self.signals.current_track.get();
                    if current.as_ref().map(|t| t.id.as_str()) == Some(&track_id) {
                        if let Some(track) = current {
                            self.send_wave_unlike(&track);
                        }
                    } else {
                        let batch = self.queue.wave_batch_for_id(&track_id);
                        self.send_wave_feedback("unlike", Some(track_id), batch, None);
                    }
                }
            }
            AudioMessage::WaveDislike(track_id) => {
                if self.queue.in_wave() {
                    let current = self.signals.current_track.get();
                    if current.as_ref().map(|t| t.id.as_str()) == Some(&track_id) {
                        if let Some(track) = current {
                            self.send_wave_dislike_skip(&track).await;
                        }
                    } else {
                        let batch = self.queue.wave_batch_for_id(&track_id);
                        self.send_wave_feedback("dislike", Some(track_id), batch, None);
                        self.queue.refresh_wave_queue();
                        self.advance_queue(AdvanceReason::Skipped(EndReason::Dislike))
                            .await;
                    }
                }
            }
            AudioMessage::WaveUndislike(track_id) => {
                if self.queue.in_wave() {
                    let current = self.signals.current_track.get();
                    if current.as_ref().map(|t| t.id.as_str()) == Some(&track_id) {
                        if let Some(track) = current {
                            self.send_wave_undislike(&track);
                        }
                    } else {
                        let batch = self.queue.wave_batch_for_id(&track_id);
                        self.send_wave_feedback("undislike", Some(track_id), batch, None);
                        self.queue.refresh_wave_queue();
                    }
                }
            }
            AudioMessage::BeginCrossfade => {
                // The monitor reached the configured fade window with a
                // preheat parked. The engine is NOT empty here (the old track
                // still plays into the fade), so there is no empty-poll
                // hazard and no buffering claim is needed. Mark the request
                // so the unified advance promotes with an overlap, then clear
                // it whatever the advance decided (a queue mismatch falls
                // back to the cold path without a stale marker).
                if self.controller.can_begin_crossfade() {
                    self.controller.request_crossfade();
                    self.advance_queue(AdvanceReason::TrackEnded).await;
                    self.controller.clear_crossfade_request();
                }
            }
            AudioMessage::SetAudioDevice(device_name) => {
                // Switch the engine first and commit the selection only on
                // success: recreate_engine leaves the old stream running
                // when the new device cannot open, and the settings UI
                // must not show a device the engine is not using.
                if let Err(e) = self.controller.recreate_engine(device_name.as_deref()).await {
                    tracing::error!(error = %e, "audio_device_switch_failed");
                    (self.error_sink)(format!("Failed to switch audio device: {e}"));
                    // recreate_engine already stopped the old players (to wake
                    // boundary watchers); the old stream is still alive, so
                    // rebuild the source on it instead of leaving silence.
                    self.reload_track().await;
                    return;
                }
                let changed = self.signals.selected_device.get() != device_name;
                self.signals.selected_device.set(device_name.clone());
                if changed {
                    tracing::info!(device = ?device_name, "audio_device_changed");
                }
                // Don't hold the actor on a DB write; persist in background.
                self.persist_setting("audio_device", &device_name);
                self.reload_track().await;
            }
            AudioMessage::RecreateStream => {
                self.recreate_stream().await;
            }
            // The actor loop breaks on this before dispatching; the arm
            // exists only to keep the match exhaustive.
            AudioMessage::Shutdown => {}
            AudioMessage::ReloadCurrentTrack => {
                self.reload_track().await;
            }
        }
    }

    async fn on_track_ended(&mut self) {
        self.advance_queue(AdvanceReason::TrackEnded).await;
    }

    async fn play_next(&mut self) {
        self.advance_queue(AdvanceReason::Skipped(EndReason::Skip))
            .await;
    }

    // Single advance path; reason selects wave_finish+get_next (natural end)
    // vs skip_wave/skip (user skip). Shared tail plays or auto-starts wave.
    async fn advance_queue(&mut self, reason: AdvanceReason) {
        // Close the outgoing listen first: the position signals still belong
        // to the outgoing track here.
        let end_reason = match reason {
            AdvanceReason::TrackEnded => EndReason::Finished,
            AdvanceReason::Skipped(end_reason) => end_reason,
        };
        self.report_track_end(end_reason);

        let next = match reason {
            AdvanceReason::TrackEnded => {
                self.queue.wave_finish_track();
                self.queue.get_next_track().await
            }
            AdvanceReason::Skipped(_) => {
                if self.queue.in_wave() {
                    self.queue.skip_wave_track().await
                } else {
                    self.queue.skip_track().await
                }
            }
        };

        if let Some(next_track) = next {
            if self.queue.in_wave() {
                self.send_wave_track_started(&next_track);
            }
            // A preheated swap keeps the audio pipeline intact across the
            // boundary (gapless); with a pending crossfade request the
            // outgoing track fades out over the overlap instead of being cut;
            // anything else cold-starts the next track through play_track.
            if self.controller.can_activate_preheat(&next_track.id) {
                if self.controller.take_crossfade_request() {
                    self.controller.begin_crossfade(next_track.clone());
                } else {
                    self.controller.activate_preheat(next_track.clone());
                }
            } else {
                self.controller
                    .play_track(next_track.clone(), false, Duration::ZERO, false)
                    .await;
            }
            self.report_track_start(&next_track, Duration::ZERO, false);
        } else {
            // Queue ended, start "My Wave"
            let yandex = self.yandex.clone();
            let generation = self.begin_context_change();
            self.spawn_fetch_context(generation, move || async move {
                yandex
                    .fetch_wave_context(vec!["user:onyourwave".to_string()])
                    .await
                    .map_err(|e| format!("Failed to auto-start wave: {e}"))
            });
        }
    }

    // ---- `/plays` listening reports (server-side history) ----

    // Wave batches are attributed per track like the desktop client.
    fn report_track_start(&mut self, track: &Track, position: Duration, paused: bool) {
        let mut ctx = self.queue.with_playback_context(PlayContext::from_playback);
        if ctx.context == "radio"
            && let Some(batch) = self.queue.wave_batch_for_track(track)
        {
            ctx.batch_id = Some(batch);
        }
        // `track.duration` wins: the duration signal may still carry the
        // outgoing track's value.
        let track_len = track
            .duration
            .unwrap_or_else(|| Duration::from_millis(self.signals.duration_ms.get()));
        self.plays
            .track_start(track, ctx, position, track_len, paused);
    }

    fn report_track_end(&mut self, reason: EndReason) {
        let position = Duration::from_millis(self.signals.position_ms.get());
        self.plays.track_end(reason, position);
    }

    fn report_pause(&mut self) {
        let position = Duration::from_millis(self.signals.position_ms.get());
        self.plays.pause(position);
    }

    fn report_resume(&mut self) {
        self.plays.resume();
    }

    fn send_wave_feedback(
        &self,
        feedback_type: &'static str,
        track_id: Option<String>,
        batch_id: Option<String>,
        total_played: Option<Duration>,
    ) {
        // Snapshot only the values the request needs: the session carries a
        // whole page of tracks, so never clone it on this hot path.
        let Some((terminated, usable, session_batch_id, radio_session_id, station_id, source_id)) =
            self.queue.with_wave_session(|s| {
                (
                    s.terminated,
                    is_usable_wave_session(s),
                    s.batch_id.clone(),
                    s.radio_session_id.clone(),
                    s.station_id().to_string(),
                    s.source_id().to_string(),
                )
            })
        else {
            return;
        };
        // Never send feedback for a dead session: without radio_session_id
        // the request goes to the user:onyourwave fallback URL with a foreign
        // batch_id (HTTP 400), and a terminated session is rejected too.
        // The session is repaired by preservation (fetcher) / recreate (queue).
        if terminated || !usable {
            tracing::error!(
                feedback_type,
                track_id = track_id.as_deref().unwrap_or("-"),
                batch_id = %session_batch_id,
                radio_session_id = radio_session_id.as_deref().unwrap_or("-"),
                terminated,
                "wave_feedback_skipped_dead_session"
            );
            return;
        }
        // Per-track batch attribution like the original client; fall back to
        // the stored session batch for tracks served before per-track
        // mapping existed. `radioStarted` carries no batch.
        let batch_id = match (track_id.is_some(), batch_id) {
            (false, _) => None,
            (true, Some(batch)) => Some(batch),
            (true, None) => Some(session_batch_id),
        };
        let from = Some(source_id);

        let api = self.yandex.api.clone();
        tokio::spawn(async move {
            if let Err(e) = api
                .send_rotor_feedback(
                    station_id.clone(),
                    batch_id.clone(),
                    feedback_type,
                    track_id.clone(),
                    from,
                    total_played,
                )
                .await
            {
                tracing::warn!(
                    error = %e,
                    feedback_type,
                    track_id = track_id.as_deref().unwrap_or("-"),
                    station_id = %station_id,
                    batch_id = batch_id.as_deref().unwrap_or("-"),
                    "wave_feedback_failed"
                );
            } else {
                // Routine per-track protocol traffic: debug keeps the file log
                // readable while failures still surface as warn above.
                tracing::debug!(
                    feedback_type,
                    track_id = track_id.as_deref().unwrap_or("-"),
                    batch_id = batch_id.as_deref().unwrap_or("-"),
                    "wave_feedback_sent"
                );
            }
        });
    }

    pub fn send_wave_started(&self) {
        self.send_wave_feedback("radioStarted", None, None, None);
    }

    pub fn send_wave_track_started(&self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        self.send_wave_feedback("trackStarted", Some(track_id), batch, None);
    }

    // Single helper for track feedback; `post` keeps the dislike-only
    // queue refresh (like/unlike leave the prefetch buffer intact).
    fn send_wave_track_with_post(
        &mut self,
        feedback_type: &'static str,
        track: &Track,
        post: WavePostAction,
    ) {
        let (track_id, batch) = system_wave::track_feedback_parts(&self.queue, track);
        self.send_wave_feedback(feedback_type, Some(track_id), batch, None);
        if post == WavePostAction::Refresh {
            self.queue.refresh_wave_queue();
        }
    }

    pub fn send_wave_like(&mut self, track: &Track) {
        // Like/unlike don't change the queue: only send feedback, keep the
        // 3-track prefetch buffer intact (refresh only on dislike).
        self.send_wave_track_with_post("like", track, WavePostAction::None);
    }

    pub fn send_wave_unlike(&mut self, track: &Track) {
        self.send_wave_track_with_post("unlike", track, WavePostAction::None);
    }

    pub fn send_wave_dislike(&mut self, track: &Track) {
        self.send_wave_track_with_post("dislike", track, WavePostAction::Refresh);
    }

    pub async fn send_wave_dislike_skip(&mut self, track: &Track) {
        self.send_wave_track_with_post("dislike", track, WavePostAction::Refresh);

        self.advance_queue(AdvanceReason::Skipped(EndReason::Dislike))
            .await;
    }

    pub fn send_wave_undislike(&mut self, track: &Track) {
        self.send_wave_track_with_post("undislike", track, WavePostAction::Refresh);
    }

    pub async fn sync_liked_collection_with(
        api: Arc<ApiService>,
        state: Arc<RwLock<SystemState>>,
        signals: AudioSignals,
        db_arc: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
    ) {
        // Revision-gated sync (official-client style): when our revision is
        // current the server answers `likedTracks: {info}` with no `values`
        // → skip DB + rebuild entirely.
        let revision = state.read().await.liked.revision;
        match api.sync_liked_tracks_collection(revision).await {
            Ok(outcome) => {
                let (new_revision, count, ids) = match outcome {
                    LikedTracksSync::Unchanged => {
                        tracing::debug!(revision = ?revision, "liked_tracks_unchanged");
                        return;
                    }
                    LikedTracksSync::Changed {
                        revision: new_revision,
                        liked_track_ids,
                        disliked_track_ids,
                    } => {
                        // Belt and suspenders (the server should send no
                        // `values` instead when unchanged).
                        if Some(new_revision) == revision {
                            return;
                        }
                        let count = liked_track_ids.len();
                        {
                            let mut state = state.write().await;
                            state.liked.apply_liked_tracks(
                                new_revision,
                                liked_track_ids,
                                disliked_track_ids,
                            );
                        }
                        let ids = state.read().await.liked.ordered_snapshot().0;
                        (new_revision, count, ids)
                    }
                };

                let mut db = db_arc.lock().await;
                // The revision must only advance when the liked save landed,
                // or the next revision-gated sync would skip the missing ids.
                match db.save_liked_tracks(&ids).await {
                    Ok(()) => {
                        if let Err(e) = db
                            .save_setting("liked_tracks_revision", &new_revision)
                            .await
                        {
                            tracing::error!(error = ?e, "persist_liked_tracks_revision_failed");
                        }
                    }
                    Err(e) => {
                        tracing::error!(error = ?e, "persist_liked_tracks_failed");
                    }
                }
                drop(db);

                signals.library_changed.send_replace(());

                tracing::info!(
                    count,
                    old_revision = ?revision,
                    new_revision = ?new_revision,
                    "liked_tracks_synced_collection"
                );
            }
            Err(e) => {
                tracing::warn!(error = ?e, "liked_collection_sync_failed");
                // Legacy fallback (servers without collection/sync): full pull.
                // No revision comes back, so the next sync retries the gated path.
                match api.fetch_liked_ids().await {
                    Ok(ids) => {
                        let count = ids.len();
                        {
                            let mut state = state.write().await;
                            state.liked.set_liked_ids(ids);
                        }
                        let liked_ids = state.read().await.liked.ordered_snapshot().0;
                        let mut db = db_arc.lock().await;
                        if let Err(e) = db.save_liked_tracks(&liked_ids).await {
                            tracing::error!(error = ?e, "persist_liked_tracks_failed");
                        }
                        drop(db);
                        signals.library_changed.send_replace(());
                        tracing::info!(count, "liked_tracks_synced_full_pull");
                    }
                    Err(e) => {
                        tracing::warn!(error = ?e, "liked_fallback_pull_failed");
                    }
                }
            }
        }
    }
}
