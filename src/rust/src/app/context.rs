use crate::api::simple::AppEvent;
use crate::audio::commands::AudioMessage;
use crate::audio::fx::EffectHandle;
use crate::audio::signals::AudioSignals;
use crate::audio::state::SystemState;
use crate::db::AppDatabase;
use crate::frb_generated::StreamSink;
use crate::http::ApiService;
use crate::storage::cache::{HttpCache, TrackCache};
use foldhash::HashMap;
use parking_lot::RwLock as StdRwLock;
use std::sync::Arc;
use tokio::sync::{Mutex, OnceCell, RwLock, mpsc, watch};

pub struct AppAudioContext {
    pub tx: mpsc::Sender<AudioMessage>,
    pub signals: AudioSignals,
    pub state: Arc<RwLock<SystemState>>,
    pub effect_handles: Arc<StdRwLock<HashMap<String, EffectHandle>>>,
}

pub struct AppCoreContext {
    pub api: Arc<ApiService>,
    pub db: Arc<Mutex<AppDatabase>>,
    pub http_cache: Arc<HttpCache>,
    pub track_cache: Arc<TrackCache>,
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
    /// Takes the dependency groups by name: nine positional handles made the
    /// call site unreadable, and the groups are the same ones the context
    /// stores, so nothing is reshaped here. The shutdown pair is created by
    /// the caller (`initialize_services`) so the audio stack can listen to
    /// the same channel it is spawned with.
    pub fn new(
        audio: AppAudioContext,
        core: AppCoreContext,
        event_sink: Arc<OnceCell<StreamSink<AppEvent>>>,
        shutdown_tx: watch::Sender<bool>,
    ) -> Self {
        let inner = Arc::new(AppContextInner {
            audio,
            core,
            system: AppSystemContext {
                event_sink,
                shutdown_tx,
            },
        });
        Self { inner }
    }

    pub fn send_event(&self, event: AppEvent) {
        if let Some(sink) = self.inner.system.event_sink.get() {
            let _ = sink.add(event);
        }
    }

    /// Stops this session's audio stack: the actor breaks out of its loop
    /// (running the listen-close + SMTC/controller teardown), and the watch
    /// releases the workers. `Drop` alone can never do this — desktop
    /// statics keep context clones alive forever — so logout must call it.
    pub async fn shutdown(&self) {
        let _ = self.inner.audio.tx.send(AudioMessage::Shutdown).await;
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
