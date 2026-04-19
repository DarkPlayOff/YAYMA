use flume::Sender;
use foldhash::HashMap;
use parking_lot::RwLock;
use rodio::Source;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use yandex_music::model::track::Track;

use crate::audio::{
    commands::AudioMessage,
    events::Event,
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

#[derive(Clone)]
pub struct AudioController {
    engine: Arc<PlaybackEngine>,
    stream_manager: Arc<StreamManager>,
    event_tx: Sender<Event>,
    pub track_progress: Arc<RwLock<Arc<TrackProgress>>>,
    current_playback_task: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
    signals: AudioSignals,
    effect_handles: Arc<RwLock<HashMap<String, EffectHandle>>>,
}

impl AudioController {
    pub fn new(
        engine: PlaybackEngine,
        stream_manager: Arc<StreamManager>,
        event_tx: Sender<Event>,
        signals: AudioSignals,
        track_progress: Arc<RwLock<Arc<TrackProgress>>>,
    ) -> Self {
        let effect_handles = crate::audio::fx::init::create_templates();
        let controller = Self {
            engine: Arc::new(engine),
            stream_manager,
            event_tx,
            track_progress,
            current_playback_task: Arc::new(Mutex::new(None)),
            signals,
            effect_handles: Arc::new(RwLock::new(effect_handles)),
        };

        controller.start_monitor();
        controller
    }

    pub fn signals(&self) -> AudioSignals {
        self.signals.clone()
    }

    fn start_monitor(&self) {
        let engine = self.engine.clone();
        let progress = self.track_progress.clone();
        let signals = self.signals.clone();
        let event_tx = self.event_tx.clone();

        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(125)).await;

                let is_playing = signals.is_playing.get();
                let is_buffering = signals.is_buffering.get();

                if is_playing && !is_buffering {
                    if engine.is_empty() {
                        signals.set_playing(false);
                        signals.is_stopped.set(true);
                        let _ = event_tx.send(Event::TrackEnded);
                        continue;
                    }

                    if signals.monitor.is_focused() {
                        let pos = engine.pos();
                        let dur = signals.duration_ms.get();

                        signals.update_progress(pos.as_millis() as u64, dur);

                        let guard = progress.read();
                        guard.set_current_position(pos);
                        let buffered = guard.get_buffered_ratio() as f32;
                        signals.update_buffered_ratio(buffered);

                        let amp = signals.monitor.combined_amplitude();
                        signals.amplitude.set(amp);
                    }
                }
            }
        });
    }

    pub async fn load(&self, track: Track, position_ms: u64) {
        let start_paused = !self.signals.is_playing.get();
        let start_pos = std::time::Duration::from_millis(position_ms);
        self.play_track(track, start_paused, start_pos, false).await;
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

    pub fn recreate_engine(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.engine.recreate()
    }

    pub async fn handle_message(&self, cmd: AudioMessage) {
        match cmd {
            AudioMessage::PlayTrack(track) => {
                self.play_track(track, false, std::time::Duration::ZERO, false)
                    .await
            }
            AudioMessage::PlayTrackPaused(track, start_pos) => {
                self.play_track(track, true, start_pos, false).await
            }
            AudioMessage::Pause => self.pause().await,
            AudioMessage::Resume => self.resume().await,
            AudioMessage::Stop => self.stop().await,
            AudioMessage::SetVolume(vol) => self.set_volume(vol as f32 / 100.0),
            AudioMessage::Seek(pos) => self.seek(pos).await,
            AudioMessage::ToggleMute => self.toggle_mute(),
            _ => {}
        }
    }

    async fn play_track(
        &self,
        track: Track,
        start_paused: bool,
        start_pos: std::time::Duration,
        soft_reload: bool,
    ) {
        self.signals.is_buffering.set(true);

        if !soft_reload {
            self.stop().await;
        } else {
            // Only stop current task and clear engine, without resetting UI signals
            let mut task_guard = self.current_playback_task.lock().await;
            if let Some(task) = task_guard.take() {
                task.abort();
            }
            self.engine.stop();
        }

        if !soft_reload {
            self.signals.is_stopped.set(false);
            self.signals.set_current_track(Some(track.clone()));
        }

        let engine = self.engine.clone();
        let stream_manager = self.stream_manager.clone();
        let progress = self.track_progress.clone();
        let event_tx = self.event_tx.clone();
        let signals = self.signals.clone();
        let track_clone = track.clone();
        let monitor = self.signals.monitor.clone();
        let effect_handles_store = self.effect_handles.clone();

        self.apply_volume();

        let task = tokio::spawn(async move {
            match stream_manager.create_stream_session(&track_clone).await {
                Ok((session, new_progress, _codec)) => {
                    {
                        let mut guard = progress.write();
                        *guard = new_progress;
                    }

                    let mut source = FxSource::new(session.source);

                    let monitor_params = Arc::new(EffectParams::new(&[]));
                    monitor_params.set_enabled(true);
                    source.add_effect(
                        "monitor",
                        "Audio Monitor",
                        Box::new(MonitorEffect::new(monitor)),
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

                    {
                        let old_store = effect_handles_store.read();
                        let new_handles = source.get_effect_handles();
                        for (name, new_handle) in new_handles.iter() {
                            if let Some(old_handle) = old_store.get(name) {
                                new_handle.set_enabled(old_handle.is_enabled());
                                for i in 0..old_handle.param_count().min(new_handle.param_count()) {
                                    new_handle.set_param(i, old_handle.get_param(i));
                                }
                            }
                        }
                    }

                    let handles = source.get_effect_handles();
                    {
                        let mut store = effect_handles_store.write();
                        *store = handles;
                    }

                    engine.play_source(source);

                    if start_pos.as_millis() > 0 {
                        let _ = engine.try_seek(start_pos);
                        let guard = progress.write();
                        guard.set_current_position(start_pos);
                    }

                    signals.is_buffering.set(false);

                    if start_paused {
                        engine.pause();
                        signals.set_playing(false);
                    } else {
                        signals.set_playing(true);
                    }

                    if !soft_reload {
                        let _ = event_tx.send(Event::TrackStarted(track_clone, 0));
                    }
                }
                Err(_e) => {
                    signals.is_buffering.set(false);
                    signals.set_playing(false);
                    signals.is_stopped.set(true);
                    let _ = event_tx.send(Event::TrackEnded);
                }
            }
        });

        let mut task_guard = self.current_playback_task.lock().await;
        *task_guard = Some(task);
    }

    async fn stop(&self) {
        let mut task_guard = self.current_playback_task.lock().await;
        if let Some(task) = task_guard.take() {
            task.abort();
        }
        self.engine.stop();
        self.track_progress.read().reset();

        self.signals.set_playing(false);
        self.signals.set_current_track(None);
        self.signals.is_stopped.set(true);
        self.signals.is_buffering.set(false);
        self.signals.update_progress(0, 0);
        self.signals.update_buffered_ratio(0.0);
    }

    async fn pause(&self) {
        self.engine.pause();
        self.signals.set_playing(false);
    }

    async fn resume(&self) {
        self.engine.play();
        self.signals.set_playing(true);
    }

    async fn seek(&self, pos: std::time::Duration) {
        let _ = self.engine.try_seek(pos);
        self.track_progress.read().set_current_position(pos);
    }

    pub fn get_effect_handles(&self) -> Arc<RwLock<HashMap<String, EffectHandle>>> {
        self.effect_handles.clone()
    }

    pub fn set_effect_handles(&self, handles: HashMap<String, EffectHandle>) {
        let mut guard = self.effect_handles.write();
        *guard = handles;
    }

    pub fn toggle_effect(&self, name: &str) -> bool {
        let guard = self.effect_handles.read();
        if let Some(handle) = guard.get(name) {
            let enabled = handle.is_enabled();
            handle.set_enabled(!enabled);
            return true;
        }
        false
    }

    pub fn is_effect_enabled(&self, name: &str) -> Option<bool> {
        let guard = self.effect_handles.read();
        guard.get(name).map(|h| h.is_enabled())
    }

    pub fn update_progress(&self, pos: Duration) {
        let dur = self.signals.duration_ms.get();
        self.signals.update_progress(pos.as_millis() as u64, dur);
    }

    pub fn current_amplitude(&self) -> f32 {
        self.signals.monitor.combined_amplitude()
    }

    pub fn is_playing(&self) -> bool {
        self.signals.is_playing.get()
    }

    pub fn current_track(&self) -> Option<Track> {
        self.signals.current_track.get()
    }

    pub fn current_track_id(&self) -> Option<String> {
        self.signals.current_track_id.get()
    }

    pub fn volume(&self) -> u8 {
        self.signals.volume.get()
    }

    pub fn is_muted(&self) -> bool {
        self.signals.is_muted.get()
    }

    pub fn set_volume(&self, volume: f32) {
        let vol_u8 = (volume * 100.0) as u8;
        self.signals.set_volume(vol_u8.min(100), false);
        self.apply_volume();
    }

    pub fn volume_up(&self, amount: u8) {
        let current = self.signals.volume.get();
        self.set_volume((current.saturating_add(amount) as f32) / 100.0);
    }

    pub fn volume_down(&self, amount: u8) {
        let current = self.signals.volume.get();
        self.set_volume((current.saturating_sub(amount) as f32) / 100.0);
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
            self.signals.volume.get() as f32 / 100.0
        };
        self.engine.set_volume(volume);
    }
}
