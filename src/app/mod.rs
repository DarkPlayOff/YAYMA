use crate::db::AppDatabase;
use parking_lot::Mutex;
use std::sync::Arc;
use tokio::sync::{Notify, OnceCell};

pub mod context;
pub mod init;
pub mod logic;
pub mod settings;
pub mod workers;

pub use context::AppContext;
pub use init::{initialize_app, initialize_infrastructure};

pub static APP_DB: OnceCell<Arc<Mutex<AppDatabase>>> = OnceCell::const_new();
pub static AUDIO_READY: Notify = Notify::const_new();
pub static SETTINGS_CHANGED: Notify = Notify::const_new();

pub fn get_db() -> Option<Arc<Mutex<AppDatabase>>> {
    APP_DB.get().cloned()
}
