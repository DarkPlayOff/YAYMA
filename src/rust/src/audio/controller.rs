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

#[derive(Clone)]
pub struct AudioController {
    engine: Arc<PlaybackEngine>,
    stream_manager: Arc<StreamManager>,
    tx: tokio::sync::mpsc::Sender<AudioMessage>,
    error_sink: Arc<dyn Fn(String) + Send + Sync>,
    pub track_progress: Arc<RwLock<Arc<TrackProgress>>>,
    current_playback_task: Arc<Mutex<Option<tokio::task::JoinHandle<()>>>>,
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
        let controller = Self {
            engine: Arc::new(engine),
            stream_manager,
            tx,
            error_sink,
            track_progress,
            current_playback_task: Arc::new(Mutex::new(None)),
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
        let progress = self.track_progress.clone();
        let signals = self.signals.clone();
        let tx = self.tx.clone();
        let error_sink = self.error_sink.clone();
        let controller = self.clone();
        let stream_error_retries = self.stream_error_retries.clone();
        let reload_in_flight = self.reload_in_flight.clone();

        tokio::spawn(async move {
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
                        buffering_duration = std::time::Duration::ZERO;
                    }
                } else {
                    buffering_duration = std::time::Duration::ZERO;
                }

                if is_playing && !is_buffering {
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
                            let _ = tx.send(AudioMessage::ReloadCurrentTrack).await;
                            continue;
                        }

                        stream_error_retries.store(0, Ordering::SeqCst);
                        signals.set_playing(false);
                        signals.is_stopped.set(true);
                        let _ = tx.send(AudioMessage::TrackEnded).await;
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
            // Only stop current task and clear engine, without resetting UI signals
            let mut task_guard = self.current_playback_task.lock().await;
            if let Some(task) = task_guard.take() {
                task.abort();
            }
            self.playback_generation.fetch_add(1, Ordering::SeqCst);
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
        let progress = self.track_progress.clone();
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

                    // Re-check right before the first engine mutation: building the source
                    // above takes long enough for a concurrent play_track()/stop() to have
                    // superseded us since the check above. Everything before this point is
                    // local to this task, so a superseded task bails without having written
                    // any shared state (progress/effect_handles_store) that a newer task may
                    // have already installed.
                    if generation.load(Ordering::SeqCst) != my_generation {
                        return;
                    }

                    {
                        let mut guard = progress.write();
                        *guard = new_progress;
                    }
                    {
                        let mut store = effect_handles_store.write();
                        *store = handles;
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
                        let guard = progress.write();
                        guard.set_current_position(start_pos);
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
                        let _ = tx.send(AudioMessage::ReloadCurrentTrack).await;
                        return;
                    }

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
        self.track_progress.read().reset();

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
        self.engine.play();
        self.signals.set_playing(true);
    }

    pub(crate) async fn seek(&self, pos: std::time::Duration) {
        let _ = self.engine.try_seek(pos);
        self.track_progress.read().set_current_position(pos);
    }

    pub fn get_effect_handles(&self) -> Arc<RwLock<HashMap<String, EffectHandle>>> {
        self.effect_handles.clone()
    }

    pub fn set_volume(&self, volume: f32) {
        let vol_u8 = (volume * 100.0) as u8;
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
