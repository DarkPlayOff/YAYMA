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
use tokio::sync::{OnceCell, RwLock, mpsc, watch};

pub struct AppAudioContext {
    pub tx: mpsc::Sender<AudioMessage>,
    pub signals: AudioSignals,
    pub state: Arc<RwLock<SystemState>>,
    pub effect_handles: Arc<StdRwLock<HashMap<String, EffectHandle>>>,
}

pub struct AppCoreContext {
    pub api: Arc<ApiService>,
    pub db: Arc<Mutex<AppDatabase>>,
}

pub struct AppSystemContext {
    pub event_sink: Arc<OnceCell<StreamSink<AppEvent>>>,
    pub shutdown_tx: watch::Sender<bool>,
}

pub struct AppContextInner {
    pub audio: AppAudioContext,
    pub core: AppCoreContext,
    pub system: AppSystemContext,
}

#[derive(Clone)]
pub struct AppContext {
    inner: Arc<AppContextInner>,
}

impl AppContext {
    pub fn new(
        audio_tx: mpsc::Sender<AudioMessage>,
        api: Arc<ApiService>,
        db: Arc<Mutex<AppDatabase>>,
        signals: AudioSignals,
        state: Arc<RwLock<SystemState>>,
        effect_handles: Arc<StdRwLock<HashMap<String, EffectHandle>>>,
    ) -> (Self, watch::Receiver<bool>) {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let inner = Arc::new(AppContextInner {
            audio: AppAudioContext {
                tx: audio_tx,
                signals,
                state,
                effect_handles,
            },
            core: AppCoreContext {
                api,
                db,
            },
            system: AppSystemContext {
                event_sink: Arc::new(OnceCell::new()),
                shutdown_tx,
            },
        });
        (Self { inner }, shutdown_rx)
    }

    pub fn send_event(&self, event: AppEvent) {
        if let Some(sink) = self.inner.system.event_sink.get() {
            let _ = sink.add(event);
        }
    }

    pub fn stop(&self) {
        let _ = self.inner.system.shutdown_tx.send(true);
    }
}

impl std::ops::Deref for AppContext {
    type Target = AppContextInner;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl Drop for AppContextInner {
    fn drop(&mut self) {
        let _ = self.system.shutdown_tx.send(true);
    }
}
