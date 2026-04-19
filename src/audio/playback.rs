use crate::audio::util::{construct_sink, setup_device_config};
use rodio::{MixerDeviceSink, Player, Source};
use std::sync::Arc;

struct EngineState {
    _stream: MixerDeviceSink,
    sink: Arc<Player>,
}

pub struct PlaybackEngine {
    state: parking_lot::RwLock<Option<EngineState>>,
    tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>,
}

impl PlaybackEngine {
    pub fn new(tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let engine = Self {
            state: parking_lot::RwLock::new(None),
            tx,
        };
        engine.recreate()?;
        Ok(engine)
    }

    pub fn recreate(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (device, stream_config, sample_format) = setup_device_config();
        
        let tx_clone = self.tx.clone();
        let error_callback = move |err: rodio::cpal::StreamError| {
            tracing::error!("Audio stream error: {:?}", err);
            let _ = tx_clone.try_send(crate::audio::commands::AudioMessage::RecreateStream);
        };

        let (stream, sink) = construct_sink(device, &stream_config, sample_format, error_callback)?;
        
        *self.state.write() = Some(EngineState {
            _stream: stream,
            sink: Arc::new(sink),
        });
        Ok(())
    }

    pub fn play_source<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.append(source);
        }
    }

    pub fn set_volume(&self, volume: f32) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.set_volume(volume);
        }
    }

    pub fn pause(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.pause();
        }
    }

    pub fn play(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.play();
        }
    }

    pub fn stop(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.sink.stop();
        }
    }

    pub fn is_paused(&self) -> bool {
        self.state.read().as_ref().map(|s| s.sink.is_paused()).unwrap_or(true)
    }

    pub fn is_empty(&self) -> bool {
        self.state.read().as_ref().map(|s| s.sink.empty()).unwrap_or(true)
    }

    pub fn pos(&self) -> std::time::Duration {
        self.state.read().as_ref().map(|s| s.sink.get_pos()).unwrap_or_default()
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
