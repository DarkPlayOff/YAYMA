use crate::api::simple::AppEvent;
use crate::audio::commands::AudioMessage;
use crate::audio::fx::EffectHandle;
use crate::audio::signals::AudioSignals;
use crate::audio::state::SystemState;
use crate::db::AppDatabase;
use crate::frb_generated::StreamSink;
use crate::http::ApiService;
use foldhash::HashMap;
use parking_lot::{Mutex, RwLock as StdRwLock};
use std::sync::Arc;
use tokio::sync::{OnceCell, RwLock, mpsc};

#[derive(Clone)]
pub struct AppContext {
    pub audio_tx: mpsc::Sender<AudioMessage>,
    pub api: Arc<ApiService>,
    pub db: Arc<Mutex<AppDatabase>>,
    pub signals: AudioSignals,
    pub state: Arc<RwLock<SystemState>>,
    pub effect_handles: Arc<StdRwLock<HashMap<String, EffectHandle>>>,
    pub event_sink: Arc<OnceCell<StreamSink<AppEvent>>>,
}

impl AppContext {
    pub fn new(
        audio_tx: mpsc::Sender<AudioMessage>,
        api: Arc<ApiService>,
        db: Arc<Mutex<AppDatabase>>,
        signals: AudioSignals,
        state: Arc<RwLock<SystemState>>,
        effect_handles: Arc<StdRwLock<HashMap<String, EffectHandle>>>,
    ) -> Self {
        Self {
            audio_tx,
            api,
            db,
            signals,
            state,
            effect_handles,
            event_sink: Arc::new(OnceCell::new()),
        }
    }

    pub fn send_event(&self, event: AppEvent) {
        if let Some(sink) = self.event_sink.get() {
            let _ = sink.add(event);
        }
    }
}
