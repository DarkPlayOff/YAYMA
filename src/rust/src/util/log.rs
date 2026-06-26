use std::path::PathBuf;
use std::sync::LazyLock;

use tracing_subscriber::{self, Layer, layer::SubscriberExt, util::SubscriberInitExt};

pub static PROJECT_NAME: LazyLock<String> =
    LazyLock::new(|| env!("CARGO_CRATE_NAME").to_uppercase().to_string());
pub static DATA_FOLDER: LazyLock<Option<PathBuf>> = LazyLock::new(|| {
    std::env::var(format!("{}_DATA", *PROJECT_NAME))
        .ok()
        .map(PathBuf::from)
});
pub static LOG_ENV: LazyLock<String> = LazyLock::new(|| format!("{}_LOGLEVEL", *PROJECT_NAME));
pub static LOG_FILE: LazyLock<String> = LazyLock::new(|| format!("{}.log", env!("CARGO_PKG_NAME")));

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub fn initialize_logging() -> Result<()> {
    let filter =
        tracing_subscriber::filter::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            tracing_subscriber::filter::EnvFilter::new(format!("{}=info", env!("CARGO_CRATE_NAME")))
        });

    // Add logging to the standard Flutter output stream (via flutter_rust_bridge)
    let console_subscriber = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stdout)
        .with_ansi(true)
        .with_filter(filter);

    let _ = tracing_subscriber::registry()
        .with(console_subscriber)
        .try_init();

    Ok(())
}
