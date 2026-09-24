use crate::audio::cache::UrlCache;
use crate::{
    audio::{
        commands::AudioMessage, controller::AudioController,
        fetcher::is_usable_wave_session, playback::PlaybackEngine, progress::TrackProgress,
        queue::QueueManager, queue::as_wave_seed, signals::AudioSignals, state::SystemState,
        stream_manager::StreamManager, yandex::YandexProvider,
    },
    http::{ApiService, SessionExt},
};

#[cfg(not(any(target_os = "android")))]
use crate::audio::{discord::DiscordManager, smtc::SmtcManager};

use parking_lot::RwLock as PRwLock;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::{RwLock, mpsc};
#[cfg(not(any(target_os = "android")))]
use tokio::sync::Mutex;
use yandex_music::model::track::Track;

pub type EffectHandles =
    Arc<parking_lot::RwLock<foldhash::HashMap<String, crate::audio::fx::EffectHandle>>>;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const PREVIOUS_TRACK_RESTART_THRESHOLD: Duration = Duration::from_secs(5);

pub struct AudioSystem {
    controller: AudioController,
    queue: QueueManager,
    yandex: YandexProvider,
    error_sink: Arc<dyn Fn(String) + Send + Sync>,
    state: Arc<RwLock<SystemState>>,
    signals: AudioSignals,
    tx: mpsc::Sender<AudioMessage>,
    db: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
    context_generation: Arc<AtomicU64>,
}

impl AudioSystem {
    pub async fn spawn(
        error_sink: Arc<dyn Fn(String) + Send + Sync>,
        api: Arc<ApiService>,
        db: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
        _http_cache: Arc<crate::storage::cache::HttpCache>,
        track_cache: Arc<crate::storage::cache::TrackCache>,
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
        let track_progress = Arc::new(PRwLock::new(track_progress_inner.clone()));

        let controller = AudioController::new(
            engine,
            stream_manager.clone(),
            tx.clone(),
            error_sink.clone(),
            signals.clone(),
            track_progress.clone(),
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
                let mut state = state.write().await;
                state.liked.set_liked_ids(ids);
                signals.library_changed.send_replace(());
            }
        }

        #[cfg(not(any(target_os = "android")))]
        let (smtc, smtc_cmd_rx) = {
            let (smtc_cmd_tx, smtc_cmd_rx) = mpsc::unbounded_channel();
            let smtc = Arc::new(Mutex::new(SmtcManager::new(
                smtc_cmd_tx,
                _http_cache.clone(),
            )?));
            (smtc, smtc_cmd_rx)
        };

        let yandex = YandexProvider::new(api.clone(), signals.clone());

        let effect_handles = controller.get_effect_handles();

        let system = Self {
            controller,
            queue,
            yandex,
            error_sink: error_sink.clone(),
            state: state.clone(),
            signals: signals.clone(),
            tx: tx.clone(),
            db,
            context_generation: Arc::new(AtomicU64::new(0)),
        };

        let mut system_loop = system;

        // Start Discord integration
        #[cfg(not(any(target_os = "android")))]
        DiscordManager::spawn(signals.clone());

        // Background task for SMTC
        #[cfg(not(any(target_os = "android")))]
        {
            let tx_clone = tx.clone();
            let mut rx_smtc = smtc_cmd_rx;
            tokio::spawn(async move {
                while let Some(msg) = rx_smtc.recv().await {
                    let _ = tx_clone.send(msg).await;
                }
            });
        }

        // Monitor signals to update SMTC
        #[cfg(not(any(target_os = "android")))]
        {
            let smtc_clone = smtc.clone();
            let signals_clone = signals.clone();
            tokio::spawn(async move {
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
        }

        // Main Audio Loop
        tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                system_loop.process_message(msg).await;
            }
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

    async fn load_context(
        &mut self,
        ctx: crate::audio::queue::PlaybackContext,
        tracks: im::Vector<Track>,
        index: usize,
    ) {
        let in_wave = matches!(&ctx, crate::audio::queue::PlaybackContext::Wave(_));
        if let Some(track) = self.queue.load(ctx, tracks, index).await {
            if in_wave {
                self.send_wave_started();
            }
            self.controller
                .play_track(track.clone(), false, Duration::ZERO, false)
                .await;
            if in_wave {
                self.send_wave_track_started(&track);
            }
        }
    }

    async fn load_fetched_context(
        &mut self,
        generation: u64,
        ctx: crate::audio::queue::PlaybackContext,
        tracks: im::Vector<Track>,
        index: usize,
    ) {
        if self.context_generation.load(Ordering::Acquire) != generation {
            return;
        }

        let in_wave = matches!(&ctx, crate::audio::queue::PlaybackContext::Wave(_));
        if let Some(track) = self.queue.load(ctx, tracks, index).await {
            // Keep the check in the actor immediately before applying the loaded
            // queue/controller state. ContextFetched messages are the only path
            // where a background fetch can reach playback.
            if self.context_generation.load(Ordering::Acquire) != generation {
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
                .play_track(track, start_paused, position, false)
                .await;
        }
    }

    async fn recreate_stream(&mut self) {
        let device = self.signals.selected_device.get();
        if let Err(e) = self.controller.recreate_engine(device.as_deref()) {
            tracing::error!("Failed to recreate stream: {}", e);
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
                    self.controller.pause().await;
                } else {
                    self.controller.resume().await;
                }
            }
            AudioMessage::Pause => self.controller.pause().await,
            AudioMessage::Resume => self.controller.resume().await,
            AudioMessage::Stop => {
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
                    self.controller.seek(Duration::ZERO).await;
                    self.signals
                        .update_progress(0, self.signals.duration_ms.get());
                } else if let Some(prev_track) = self.queue.get_previous_track() {
                    self.controller
                        .play_track(prev_track, false, Duration::ZERO, false)
                        .await;
                }
            }
            AudioMessage::TrackEnded => {
                self.on_track_ended().await;
            }
            AudioMessage::Seek(dur) => self.controller.seek(dur).await,
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
            AudioMessage::ToggleShuffle => self.queue.toggle_shuffle(),
            AudioMessage::ToggleRepeatMode => self.queue.toggle_repeat_mode(),

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
                let generation = self.begin_context_change();
                // Offline check + DB read run in background so the actor stays
                // responsive to Pause/Seek/Next while they complete.
                let tx = self.tx.clone();
                let stream_manager = self.queue.stream_manager.clone();
                let db = self.db.clone();
                let yandex = self.yandex.clone();
                tokio::spawn(async move {
                    let local_ctx =
                        if stream_manager.is_track_offline(&tid).await {
                            Self::build_single_track_offline_static(&db, &tid).await
                        } else {
                            None
                        };
                    if let Some((tracks, index)) = local_ctx {
                        let _ = tx
                            .send(AudioMessage::LoadContext(
                                crate::audio::queue::PlaybackContext::Standalone,
                                tracks,
                                index,
                            ))
                            .await;
                    } else {
                        match yandex.fetch_album_context(aid, Some(tid)).await {
                            Ok((ctx, tracks, index)) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Ok((ctx, tracks, index)),
                                    })
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Err(format!("Failed to load album: {e}")),
                                    })
                                    .await;
                            }
                        }
                    }
                });
            }
            AudioMessage::PlayPlaylistTrack(kind, tid) => {
                let generation = self.begin_context_change();
                let tx = self.tx.clone();
                let stream_manager = self.queue.stream_manager.clone();
                let db = self.db.clone();
                let yandex = self.yandex.clone();
                tokio::spawn(async move {
                    let local_ctx =
                        if stream_manager.is_track_offline(&tid).await {
                            Self::build_single_track_offline_static(&db, &tid).await
                        } else {
                            None
                        };
                    if let Some((tracks, index)) = local_ctx {
                        let _ = tx
                            .send(AudioMessage::LoadContext(
                                crate::audio::queue::PlaybackContext::Standalone,
                                tracks,
                                index,
                            ))
                            .await;
                    } else {
                        match yandex.fetch_playlist_context(kind, Some(tid)).await {
                            Ok((ctx, tracks, index)) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Ok((ctx, tracks, index)),
                                    })
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Err(format!(
                                            "Failed to load playlist track: {e}"
                                        )),
                                    })
                                    .await;
                            }
                        }
                    }
                });
            }
            AudioMessage::PlayLikedTrack(tid) => {
                let generation = self.begin_context_change();
                let tx = self.tx.clone();
                let stream_manager = self.queue.stream_manager.clone();
                let db = self.db.clone();
                let state = self.state.clone();
                let yandex = self.yandex.clone();
                tokio::spawn(async move {
                    let local_ctx =
                        if stream_manager.is_track_offline(&tid).await {
                            Self::build_local_liked_context_static(&db, &state, &tid).await
                        } else {
                            None
                        };
                    if let Some((tracks, index)) = local_ctx {
                        let _ = tx
                            .send(AudioMessage::LoadContext(
                                crate::audio::queue::PlaybackContext::Standalone,
                                tracks,
                                index,
                            ))
                            .await;
                    } else {
                        match yandex.fetch_liked_context(Some(tid)).await {
                            Ok((ctx, tracks, index)) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Ok((ctx, tracks, index)),
                                    })
                                    .await;
                            }
                            Err(e) => {
                                let _ = tx
                                    .send(AudioMessage::ContextFetched {
                                        generation,
                                        result: Err(format!("Failed to load liked track: {e}")),
                                    })
                                    .await;
                            }
                        }
                    }
                });
            }
            AudioMessage::StartWave(seeds) => {
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
                        self.play_next().await;
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
            AudioMessage::SetAudioDevice(device_name) => {
                self.signals.selected_device.set(device_name.clone());
                // Don't hold the actor on a DB write; persist in background.
                let db = self.db.clone();
                tokio::spawn(async move {
                    let mut db = db.lock().await;
                    let _ = db.save_setting("audio_device", &device_name).await;
                });
                self.recreate_stream().await;
            }
            AudioMessage::RecreateStream => {
                self.recreate_stream().await;
            }
            AudioMessage::ReloadCurrentTrack => {
                self.reload_track().await;
            }
        }
    }

    async fn on_track_ended(&mut self) {
        self.queue.wave_finish_track();

        if let Some(next_track) = self.queue.get_next_track().await {
            if self.queue.in_wave() {
                self.send_wave_track_started(&next_track);
            }
            self.controller
                .play_track(next_track, false, Duration::ZERO, false)
                .await;
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

    async fn play_next(&mut self) {
        let next = if self.queue.in_wave() {
            self.queue.skip_wave_track().await
        } else {
            self.queue.skip_track().await
        };

        if let Some(next_track) = next {
            if self.queue.in_wave() {
                self.send_wave_track_started(&next_track);
            }
            self.controller
                .play_track(next_track, false, Duration::ZERO, false)
                .await;
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

    fn send_wave_feedback(
        &self,
        feedback_type: &'static str,
        track_id: Option<String>,
        batch_id: Option<String>,
        total_played: Option<Duration>,
    ) {
        let session = match self.queue.wave_context() {
            Some(s) => s,
            None => return,
        };
        // Never send feedback for a dead session: without radio_session_id
        // the request goes to the user:onyourwave fallback URL with a foreign
        // batch_id (HTTP 400), and a terminated session is rejected too.
        // The session is repaired by preservation (fetcher) / recreate (queue).
        if session.terminated || !is_usable_wave_session(&session) {
            tracing::error!(
                feedback_type,
                track_id = track_id.as_deref().unwrap_or("-"),
                batch_id = %session.batch_id,
                radio_session_id = session.radio_session_id.as_deref().unwrap_or("-"),
                terminated = session.terminated,
                "wave_feedback_skipped_dead_session"
            );
            return;
        }
        let station_id = session.station_id().to_string();
        // Per-track batch attribution like the original client; fall back to
        // the stored session batch for tracks served before per-track
        // mapping existed. `radioStarted` carries no batch.
        let batch_id = match (track_id.is_some(), batch_id) {
            (false, _) => None,
            (true, Some(batch)) => Some(batch),
            (true, None) => Some(session.batch_id.clone()),
        };
        let from = Some(session.source_id().to_string());

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
                tracing::info!(feedback_type, "wave_feedback_sent");
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

    pub fn send_wave_like(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        // Like/unlike don't change the queue: only send feedback, keep the
        // 3-track prefetch buffer intact (refresh only on dislike).
        self.send_wave_feedback("like", Some(track_id), batch, None);
    }

    pub fn send_wave_unlike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        self.send_wave_feedback("unlike", Some(track_id), batch, None);
    }

    pub fn send_wave_dislike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        self.send_wave_feedback("dislike", Some(track_id), batch, None);
        self.queue.refresh_wave_queue();
    }

    pub async fn send_wave_dislike_skip(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        self.send_wave_feedback("dislike", Some(track_id), batch, None);
        self.queue.refresh_wave_queue();

        self.play_next().await;
    }

    pub fn send_wave_undislike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        let batch = self.queue.wave_batch_for_track(track);
        self.send_wave_feedback("undislike", Some(track_id), batch, None);
        self.queue.refresh_wave_queue();
    }

    async fn build_local_liked_context_static(
        db: &Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
        state: &Arc<RwLock<SystemState>>,
        track_id: &str,
    ) -> Option<(im::Vector<Track>, usize)> {
        let (liked_ids, _) = state.read().await.liked.ordered_snapshot();
        if liked_ids.is_empty() {
            return None;
        }

        let metadata = db
            .lock()
            .await
            .get_track_metadata(&liked_ids)
            .await
            .ok()?;
        let mut metadata_map: foldhash::HashMap<String, crate::storage::db::TrackMetadata> = {
            use foldhash::HashMapExt;
            foldhash::HashMap::new()
        };
        for m in metadata {
            metadata_map.insert(m.id.clone(), m);
        }

        let mut tracks = im::Vector::new();
        let mut index = None;
        for id in &liked_ids {
            if let Some(m) = metadata_map.remove(id) {
                if id == track_id {
                    index = Some(tracks.len());
                }
                tracks.push_back(crate::util::track::track_from_metadata(&m));
            }
        }

        Some((tracks, index?))
    }

    /// Builds a single-track playback queue from locally cached (DB) metadata,
    /// without any network access. Used as an offline fallback for album/playlist
    /// tracks, where (unlike liked tracks) we don't keep a local ordered track
    /// list to reconstruct the full queue context.
    async fn build_single_track_offline_static(
        db: &Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
        track_id: &str,
    ) -> Option<(im::Vector<Track>, usize)> {
        let ids = vec![track_id.to_string()];
        let metadata = db.lock().await.get_track_metadata(&ids).await.ok()?;
        let m = metadata.into_iter().find(|m| m.id == track_id)?;
        let mut tracks = im::Vector::new();
        tracks.push_back(crate::util::track::track_from_metadata(&m));
        Some((tracks, 0))
    }

    pub async fn sync_liked_collection_with(
        api: Arc<ApiService>,
        state: Arc<RwLock<SystemState>>,
        signals: AudioSignals,
        db_arc: Arc<tokio::sync::Mutex<crate::db::AppDatabase>>,
    ) {
        if let Ok(ids) = api.fetch_liked_ids().await {
            let count = ids.len();

            let mut db = db_arc.lock().await;
            let _ = db.save_liked_tracks(&ids).await;

            {
                let mut state = state.write().await;
                state.liked.set_liked_ids(ids);
            }
            signals.library_changed.send_replace(());

            tracing::info!("Synced {} liked track IDs directly from API", count);
        } else {
            tracing::warn!("Failed to fetch liked track IDs");
        }
    }
}
