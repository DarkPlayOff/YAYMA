use tokio::sync::Notify;

pub mod context;
pub mod hotkeys;
pub mod init;
pub mod settings;
pub mod workers;

pub use context::AppContext;
pub use init::{get_data_dir, get_database, initialize_app, initialize_infrastructure};

pub static AUDIO_READY: Notify = Notify::const_new();
pub static SETTINGS_CHANGED: Notify = Notify::const_new();
