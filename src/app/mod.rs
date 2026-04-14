use crate::db::AppDatabase;
use arc_swap::ArcSwapOption;
use parking_lot::Mutex;
use std::sync::Arc;
use tokio::sync::{Notify, OnceCell};

pub mod context;
pub mod init;
pub mod logic;
pub mod session;
pub mod settings;
pub mod workers;

pub use context::AppContext;
pub use init::{initialize_app, initialize_infrastructure, stop_current_session};
pub use session::AppSession;

pub static APP_DB: OnceCell<Arc<Mutex<AppDatabase>>> = OnceCell::const_new();
pub static AUDIO_READY: Notify = Notify::const_new();
pub static SETTINGS_CHANGED: Notify = Notify::const_new();

pub static CURRENT_SESSION: ArcSwapOption<session::AppSession> = ArcSwapOption::const_empty();

pub fn get_audio_tx() -> Option<tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>> {
    CURRENT_SESSION
        .load()
        .as_ref()
        .map(|s| s.context.audio_tx.clone())
}

pub fn get_context() -> Option<Arc<AppContext>> {
    CURRENT_SESSION.load().as_ref().map(|s| s.context.clone())
}

pub fn get_api() -> Option<Arc<crate::http::ApiService>> {
    CURRENT_SESSION
        .load()
        .as_ref()
        .map(|s| s.context.api.clone())
}

pub fn get_db() -> Option<Arc<Mutex<AppDatabase>>> {
    APP_DB.get().cloned()
}
