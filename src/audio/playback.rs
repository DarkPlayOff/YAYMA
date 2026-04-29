use crate::audio::util::{construct_sink, setup_device_config};
use rodio::{MixerDeviceSink, Player, Source};
use std::num::NonZero;
use std::sync::Arc;
use parking_lot::RwLock;

struct EngineState {
    _stream: MixerDeviceSink,
    sink: Arc<Player>,
    // We'll use a second sink for crossfading
    crossfade_sink: Arc<Player>,
    sample_rate: NonZero<u32>,
    channels: NonZero<u16>,
}

pub struct PlaybackEngine {
    state: RwLock<Option<EngineState>>,
    tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>,
}

impl PlaybackEngine {
    pub fn new(tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let engine = Self {
            state: RwLock::new(None),
            tx,
        };
        engine.recreate()?;
        Ok(engine)
    }

    pub fn recreate(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (device, stream_config, sample_format) = setup_device_config();
        let sample_rate = NonZero::new(stream_config.sample_rate).unwrap();
        let channels = NonZero::new(stream_config.channels).unwrap();
        
        let tx_clone = self.tx.clone();
        let error_callback = move |err: rodio::cpal::StreamError| {
            tracing::error!("Audio stream error: {:?}", err);
            let _ = tx_clone.try_send(crate::audio::commands::AudioMessage::RecreateStream);
        };

        let (stream, sink) = construct_sink(device.clone(), &stream_config, sample_format, error_callback.clone())?;
        // Create a second player connected to the same mixer for crossfading
        let crossfade_sink = Player::connect_new(stream.mixer());
        
        *self.state.write() = Some(EngineState {
            _stream: stream,
            sink: Arc::new(sink),
            crossfade_sink: Arc::new(crossfade_sink),
            sample_rate,
            channels,
        });
        Ok(())
    }

    pub fn play_source<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        if let Some(state) = self.state.read().as_ref() {
            let resampled = rodio::source::UniformSourceIterator::new(source, state.channels, state.sample_rate);
            state.sink.append(resampled);
        }
    }

    pub fn play_crossfade<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        if let Some(state) = self.state.read().as_ref() {
            let resampled = rodio::source::UniformSourceIterator::new(source, state.channels, state.sample_rate);
            state.crossfade_sink.append(resampled);
        }
    }

    pub fn set_volume(&self, volume: f32) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.set_volume(volume);
        }
    }

    pub fn set_crossfade_volume(&self, volume: f32) {
        if let Some(state) = self.state.read().as_ref() {
            state.crossfade_sink.set_volume(volume);
        }
    }

    pub fn set_all_volumes(&self, volume: f32) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.set_volume(volume);
            state.crossfade_sink.set_volume(volume);
        }
    }

    pub fn pause(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.pause();
            state.crossfade_sink.pause();
        }
    }

    pub fn play(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.play();
            state.crossfade_sink.play();
        }
    }

    pub fn stop(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.stop();
            state.crossfade_sink.stop();
        }
    }

    pub fn stop_primary(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.stop();
        }
    }

    pub fn swap_sinks(&self) {
        let mut guard = self.state.write();
        if let Some(state) = guard.as_mut() {
            std::mem::swap(&mut state.sink, &mut state.crossfade_sink);
        }
    }

    pub fn is_paused(&self) -> bool {
        self.state.read().as_ref().map(|s| s.sink.is_paused()).unwrap_or(true)
    }

    pub fn is_empty(&self) -> bool {
        self.state.read().as_ref().map(|s| s.sink.empty() && s.crossfade_sink.empty()).unwrap_or(true)
    }

    pub fn pos(&self) -> std::time::Duration {
        if let Some(state) = self.state.read().as_ref() {
            if !state.crossfade_sink.empty() {
                state.crossfade_sink.get_pos()
            } else {
                state.sink.get_pos()
            }
        } else {
            std::time::Duration::ZERO
        }
    }

    pub fn try_seek(
        &self,
        pos: std::time::Duration,
    ) -> std::result::Result<(), rodio::source::SeekError> {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.try_seek(pos)
        } else {
            Err(rodio::source::SeekError::NotSupported {
                underlying_source: "Stream not initialized",
            })
        }
    }
}
