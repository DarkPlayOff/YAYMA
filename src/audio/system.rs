use std::sync::Arc;
use std::time::Duration;

use parking_lot::RwLock as PRwLock;
use tokio::sync::{mpsc, Mutex, RwLock};
use yandex_music::model::track::Track;

use crate::http::{ApiService, SessionExt};
use crate::audio::commands::AudioMessage;
use crate::audio::controller::AudioController;
use crate::audio::discord::DiscordManager;
use crate::audio::events::Event;
use crate::audio::queue::{QueueManager, as_wave_seed};
use crate::audio::signals::AudioSignals;
use crate::audio::smtc::SmtcManager;
use crate::audio::stream_manager::StreamManager;
use crate::audio::yandex::YandexProvider;
use crate::audio::cache::UrlCache;
use crate::audio::progress::TrackProgress;
use crate::audio::fx::EffectHandle;
use foldhash::HashMap;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

use crate::audio::state::SystemState;

pub struct AudioSystem {
    controller: AudioController,
    queue: QueueManager,
    yandex: YandexProvider,
    event_tx: flume::Sender<Event>,
    state: Arc<RwLock<SystemState>>,
    signals: AudioSignals,
    smtc: Arc<Mutex<SmtcManager>>,
    tx: mpsc::Sender<AudioMessage>,
}

impl AudioSystem {
    pub async fn spawn(
        event_tx: flume::Sender<Event>,
        api: Arc<ApiService>,
    ) -> Result<(mpsc::Sender<AudioMessage>, AudioSignals, Arc<RwLock<SystemState>>, Arc<PRwLock<HashMap<String, EffectHandle>>>)> {
        let url_cache = UrlCache::new();
        Self::new(api, url_cache, event_tx).await
    }

    pub async fn new(
        api: Arc<ApiService>,
        url_cache: UrlCache,
        event_tx: flume::Sender<Event>,
    ) -> Result<(mpsc::Sender<AudioMessage>, AudioSignals, Arc<RwLock<SystemState>>, Arc<PRwLock<HashMap<String, EffectHandle>>>)> {
        let (tx, mut rx) = mpsc::channel(100);

        let engine = crate::audio::playback::PlaybackEngine::new(tx.clone())?;

        let stream_manager = Arc::new(
            tokio::task::spawn_blocking({
                let api = api.clone();
                let url_cache = url_cache.clone();
                move || StreamManager::new(api, url_cache)
            })
            .await
            .map_err(|e| e.to_string())?,
        );

        let signals = AudioSignals::new();
        let track_progress_inner = Arc::new(TrackProgress::default());
        let track_progress = Arc::new(PRwLock::new(track_progress_inner.clone()));

        let controller = AudioController::new(
            engine,
            stream_manager.clone(),
            event_tx.clone(),
            tx.clone(),
            signals.clone(),
            track_progress.clone(),
        );

        let mut queue = QueueManager::new(
            api.clone(),
            url_cache,
            stream_manager.clone(),
            signals.clone(),
            track_progress_inner,
        );
        queue.set_event_tx(event_tx.clone());

        let state = Arc::new(RwLock::new(SystemState::default()));
        let (smtc_cmd_tx, mut smtc_cmd_rx) = mpsc::unbounded_channel();
        let smtc = Arc::new(Mutex::new(SmtcManager::new(event_tx.clone(), smtc_cmd_tx)?));
        let yandex = YandexProvider::new(api.clone(), event_tx.clone(), signals.clone());

        let effect_handles = controller.get_effect_handles();

        let mut system = Self {
            controller,
            queue,
            yandex,
            event_tx: event_tx.clone(),
            state: state.clone(),
            signals: signals.clone(),
            smtc,
            tx: tx.clone(),
        };

        // Start Discord integration
        DiscordManager::spawn(signals.clone());

        // Background task for SMTC
        let tx_clone = tx.clone();
        tokio::spawn(async move {
            while let Some(msg) = smtc_cmd_rx.recv().await {
                let _ = tx_clone.send(msg).await;
            }
        });

        // Monitor signals to update SMTC
        let smtc_clone = system.smtc.clone();
        let signals_clone = signals.clone();
        tokio::spawn(async move {
            let mut last_track_id = None;
            let mut last_playing = false;

            loop {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;

                let current_track = signals_clone.current_track.get();
                let current_track_id = current_track.as_ref().map(|t| t.id.clone());
                let is_playing = signals_clone.is_playing.get();

                let mut smtc = smtc_clone.lock().await;

                if current_track_id != last_track_id {
                    if let Some(track) = current_track {
                        smtc.update_metadata(&track);
                    }
                    last_track_id = current_track_id;
                }

                if is_playing != last_playing {
                    smtc.update_playback_status(is_playing);
                    last_playing = is_playing;
                }
            }
        });

        // Main Audio Loop
        let event_tx_clone = event_tx.clone();
        tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                if let Err(e) = system.handle_message(msg).await {
                    tracing::error!("Audio system error: {}", e);
                    let _ = event_tx_clone.send(Event::Error(e.to_string()));
                }
            }
        });

        Ok((tx, signals, state, effect_handles))
    }

    fn spawn_fetch_context<F, Fut>(&self, fetcher: F)
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: std::future::Future<
                Output = std::result::Result<
                    (
                        crate::audio::queue::PlaybackContext,
                        im::Vector<yandex_music::model::track::Track>,
                        usize,
                    ),
                    Box<dyn std::error::Error + Send + Sync>,
                >,
            > + Send
            + 'static,
    {
        let tx = self.tx.clone();
        let event_tx = self.event_tx.clone();
        self.signals.is_buffering.set(true);
        tokio::spawn(async move {
            match fetcher().await {
                Ok((ctx, tracks, index)) => {
                    let _ = tx.send(AudioMessage::LoadContext(ctx, tracks, index)).await;
                }
                Err(e) => {
                    let _ = event_tx.send(Event::Error(e.to_string()));
                }
            }
        });
    }

    async fn handle_message(&mut self, msg: AudioMessage) -> Result<()> {
        match msg {
            AudioMessage::PlayPause => {
                if self.signals.is_playing.get() {
                    self.controller.handle_message(AudioMessage::Pause).await;
                } else {
                    self.controller.handle_message(AudioMessage::Resume).await;
                }
            }
            AudioMessage::Pause => self.controller.handle_message(AudioMessage::Pause).await,
            AudioMessage::Resume => self.controller.handle_message(AudioMessage::Resume).await,
            AudioMessage::Stop => {
                self.controller.handle_message(AudioMessage::Stop).await;
                self.queue.clear();
            }
            AudioMessage::Next => {
                self.play_next().await;
            }
            AudioMessage::Prev => {
                if let Some(prev_track) = self.queue.get_previous_track() {
                    if self.signals.crossfade_enabled.get() {
                        self.controller.handle_message(AudioMessage::PlayTrackFastFade(prev_track)).await;
                    } else {
                        self.controller.handle_message(AudioMessage::PlayTrack(prev_track)).await;
                    }
                }
            }
            AudioMessage::TrackEnded => {
                self.on_track_ended().await;
            }
            AudioMessage::Seek(dur) => {
                self.controller
                    .handle_message(AudioMessage::Seek(dur))
                    .await
            }
            AudioMessage::SetVolume(vol) => self.controller.set_volume(vol as f32 / 100.0),
            AudioMessage::ToggleMute => self.controller.toggle_mute(),

            AudioMessage::PlayTrack(track) => {
                if let Some(playing_track) = self
                    .queue
                    .load(
                        crate::audio::queue::PlaybackContext::Track(Box::new(track.clone())),
                        im::Vector::from(vec![track]),
                        0,
                    )
                    .await
                {
                    if self.signals.crossfade_enabled.get() && self.signals.is_playing.get() {
                        self.controller.handle_message(AudioMessage::PlayTrackFastFade(playing_track)).await;
                    } else {
                        self.controller.handle_message(AudioMessage::PlayTrack(playing_track)).await;
                    }
                }
            }
            AudioMessage::PlayTrackCrossfade(track) => {
                self.controller
                    .handle_message(AudioMessage::PlayTrackCrossfade(track))
                    .await;
            }
            AudioMessage::PlayTrackFastFade(track) => {
                self.controller
                    .handle_message(AudioMessage::PlayTrackFastFade(track))
                    .await;
            }
            AudioMessage::PlayTrackPaused(track, pos) => {
                if let Some(playing_track) = self
                    .queue
                    .load(
                        crate::audio::queue::PlaybackContext::Track(Box::new(track.clone())),
                        im::Vector::from(vec![track]),
                        0,
                    )
                    .await
                {
                    self.controller
                        .handle_message(AudioMessage::PlayTrackPaused(playing_track, pos))
                        .await;
                }
            }
            AudioMessage::LoadContext(ctx, tracks, index) => {
                let in_wave = matches!(&ctx, crate::audio::queue::PlaybackContext::Wave(_));
                if let Some(track) = self.queue.load(ctx, tracks, index).await {
                    if in_wave {
                        self.send_wave_started();
                    }
                    if self.signals.crossfade_enabled.get() && self.signals.is_playing.get() {
                        self.controller.handle_message(AudioMessage::PlayTrackFastFade(track.clone())).await;
                    } else {
                        self.controller.handle_message(AudioMessage::PlayTrack(track.clone())).await;
                    }
                    if in_wave {
                        self.send_wave_track_started(&track);
                    }
                }
            }
            AudioMessage::LoadTracks(tracks) => {
                if let Some(track) = self
                    .queue
                    .load(
                        crate::audio::queue::PlaybackContext::Standalone,
                        im::Vector::from(tracks),
                        0,
                    )
                    .await
                {
                    if self.signals.crossfade_enabled.get() && self.signals.is_playing.get() {
                        self.controller.handle_message(AudioMessage::PlayTrackFastFade(track)).await;
                    } else {
                        self.controller.handle_message(AudioMessage::PlayTrack(track)).await;
                    }
                }
            }
            AudioMessage::QueueTrack(track) => self.queue.queue_track(track),
            AudioMessage::PlayTrackNext(track) => self.queue.play_next(track),
            AudioMessage::RemoveFromQueue(idx) => self.queue.remove_track(idx),
            AudioMessage::ClearQueue => self.queue.clear(),
            AudioMessage::ToggleShuffle => self.queue.toggle_shuffle(),
            AudioMessage::ToggleRepeatMode => self.queue.toggle_repeat_mode(),

            AudioMessage::PlayPlaylist(kind) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_playlist_context(kind, None)
                        .await
                });
            }
            AudioMessage::PlayAlbum(album_id) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_album_context(album_id, None)
                        .await
                });
            }
            AudioMessage::PlayAlbumTrack(aid, tid) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_album_context(aid, Some(tid))
                        .await
                });
            }
            AudioMessage::PlayPlaylistTrack(pid, tid) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_playlist_context(pid, Some(tid))
                        .await
                });
            }
            AudioMessage::PlayLikedTrack(tid) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_liked_context(Some(tid))
                        .await
                });
            }
            AudioMessage::StartWave(seeds) => {
                let yandex = self.yandex.clone();
                self.spawn_fetch_context(move || async move {
                    yandex
                        .fetch_wave_context(seeds)
                        .await
                });
            }
            AudioMessage::SyncLiked => {
                let yandex = self.yandex.clone();
                let state = self.state.clone();
                let signals = self.signals.clone();
                tokio::spawn(async move {
                    let _ = Self::sync_liked_collection_with(yandex, state, signals).await;
                });
            }
            AudioMessage::WaveLike(id) => self.send_wave_feedback("like", Some(id), None, true),
            AudioMessage::WaveUnlike(id) => self.send_wave_feedback("unlike", Some(id), None, true),
            AudioMessage::WaveDislike(id) => {
                let track = self.signals.current_track.get();
                if let Some(t) = track {
                    if t.id == id {
                        let mut system = self.clone_for_wave();
                        tokio::spawn(async move {
                            system.send_wave_dislike_skip(&t).await;
                        });
                    } else {
                        self.send_wave_feedback("dislike", Some(id), None, true);
                    }
                } else {
                    self.send_wave_feedback("dislike", Some(id), None, true);
                }
            }
            AudioMessage::WaveUndislike(id) => self.send_wave_feedback("undislike", Some(id), None, true),

            AudioMessage::ReloadCurrentTrack => {
                if let Some(track) = self.signals.current_track.get() {
                    let pos = self.signals.position_ms.get();
                    self.controller.replace_track(track, pos).await;
                }
            }
            AudioMessage::RecreateStream => {
                let _ = self.controller.recreate_engine();
            }
            AudioMessage::PrewarmNext => {
                self.queue.prewarm_next();
            }
            AudioMessage::CrossfadeNext => {
                self.queue.wave_finish_track();
                if let Some(next_track) = self.queue.get_next_track().await {
                    if self.queue.in_wave() {
                        self.send_wave_track_started(&next_track);
                    }
                    let _ = self.tx.send(AudioMessage::PlayTrackCrossfade(next_track)).await;
                }
            }
        }
        Ok(())
    }

    async fn on_track_ended(&mut self) {
        self.queue.wave_finish_track();

        if let Some(next_track) = self.queue.get_next_track().await {
            if self.queue.in_wave() {
                self.send_wave_track_started(&next_track);
            }
            self.controller
                .handle_message(AudioMessage::PlayTrack(next_track))
                .await;
        } else {
            let _ = self.event_tx.send(Event::QueueEnded);
        }
    }

    async fn play_next(&mut self) {
        let next = if self.queue.in_wave() {
            self.queue.skip_wave_track().await
        } else {
            self.queue.get_next_track().await
        };

        if let Some(next_track) = next {
            if self.queue.in_wave() {
                self.send_wave_track_started(&next_track);
            }
            if self.signals.crossfade_enabled.get() {
                self.controller.handle_message(AudioMessage::PlayTrackFastFade(next_track)).await;
            } else {
                self.controller.handle_message(AudioMessage::PlayTrack(next_track)).await;
            }
        } else {
            let _ = self.event_tx.send(Event::QueueEnded);
        }
    }

    fn clone_for_wave(&self) -> Self {
        Self {
            controller: self.controller.clone(),
            queue: self.queue.clone(),
            yandex: self.yandex.clone(),
            event_tx: self.event_tx.clone(),
            state: self.state.clone(),
            signals: self.signals.clone(),
            smtc: self.smtc.clone(),
            tx: self.tx.clone(),
        }
    }

    fn send_wave_feedback(
        &self,
        feedback_type: &'static str,
        track_id: Option<String>,
        total_played: Option<Duration>,
        include_batch_id: bool,
    ) {
        let session = match self.queue.wave_context() {
            Some(s) => s,
            None => return,
        };
        let station_id = session.station_id().to_string();
        let batch_id = if include_batch_id {
            session.radio_session_id.clone()
        } else {
            None
        };

        let api = self.yandex.api.clone();
        tokio::spawn(async move {
            let _ = api.send_rotor_feedback(
                    station_id,
                    batch_id,
                    feedback_type,
                    track_id,
                    None,
                    total_played,
                )
                .await;
        });
    }

    pub fn send_wave_started(&self) {
        self.send_wave_feedback("radioStarted", None, None, false);
    }

    pub fn send_wave_track_started(&self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("trackStarted", Some(track_id), None, true);
    }

    pub fn send_wave_like(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("like", Some(track_id), None, true);
        self.queue.refresh_wave_queue();
    }

    pub fn send_wave_unlike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("unlike", Some(track_id), None, true);
        self.queue.refresh_wave_queue();
    }

    pub fn send_wave_dislike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("dislike", Some(track_id), None, true);
        self.queue.refresh_wave_queue();
    }

    pub async fn send_wave_dislike_skip(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("dislike", Some(track_id), None, true);
        self.queue.refresh_wave_queue();

        self.play_next().await;
    }

    pub fn send_wave_undislike(&mut self, track: &Track) {
        let track_id = as_wave_seed(track);
        self.send_wave_feedback("undislike", Some(track_id), None, true);
        self.queue.refresh_wave_queue();
    }

    pub async fn sync_liked_collection_with(
        yandex: YandexProvider,
        _state: Arc<RwLock<SystemState>>,
        signals: AudioSignals,
    ) -> Result<()> {
        if let Ok(ids) = yandex.api.fetch_liked_ids().await {
            // Sync with DB
            if let Some(db_arc) = crate::app::get_db() {
                let ids_for_db = ids.clone();
                tokio::task::spawn_blocking(move || {
                    let db = db_arc.lock();
                    let _ = db.save_liked_tracks(&ids_for_db);
                });
            }

            signals.library_changed.send_replace(());
        }
        Ok(())
    }
}
