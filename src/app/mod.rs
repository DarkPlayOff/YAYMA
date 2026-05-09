use tokio::sync::Notify;

pub mod context;
pub mod init;
pub mod logic;
pub mod settings;
pub mod workers;

pub use context::AppContext;
pub use init::{initialize_app, initialize_infrastructure};

pub static AUDIO_READY: Notify = Notify::const_new();
pub static SETTINGS_CHANGED: Notify = Notify::const_new();
