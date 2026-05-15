use crate::app::context::AppContext;
use crate::app::settings::load_persisted_settings;
use crate::app::workers;
use crate::app::{AUDIO_READY};
use crate::audio::system::AudioSystem;
use crate::db::AppDatabase;
use crate::http::ApiService;
use crate::storage::cache::HttpCache;
use parking_lot::Mutex;
use std::sync::Arc;
use std::path::PathBuf;
use std::sync::OnceLock;

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

pub fn get_data_dir() -> Option<PathBuf> {
    DATA_DIR.get().cloned()
}

/// Complete application initialization cycle
pub async fn initialize_app(
    api: ApiService,
) -> Result<AppContext, Box<dyn std::error::Error + Send + Sync>> {
    initialize_services(api).await
}

/// Initialize base infrastructure (logging, panic hook, DB)
/// Called once at FRB startup
pub fn initialize_infrastructure(base_path: Option<String>) {
    if let Some(path) = base_path {
        let p = PathBuf::from(path);
        std::fs::create_dir_all(&p).ok();
        DATA_DIR.set(p).ok();
    }

    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        flutter_rust_bridge::setup_default_user_utils();
        crate::util::hook::set_panic_hook();
        let _ = crate::util::log::initialize_logging();
    });
}

async fn initialize_services(
    api: ApiService,
) -> Result<AppContext, Box<dyn std::error::Error + Send + Sync>> {
    let api_arc = Arc::new(api);
    let (event_tx, event_rx) = flume::unbounded();

    let db = AppDatabase::init(DATA_DIR.get().cloned())?;
    let db_arc = Arc::new(Mutex::new(db));
    let http_cache = Arc::new(HttpCache::new(db_arc.clone(), DATA_DIR.get().cloned()));

    let (audio_tx, signals, state, effect_handles) =
        AudioSystem::spawn(event_tx.clone(), api_arc.clone(), db_arc.clone(), http_cache.clone()).await?;

    let (context, shutdown_rx) = AppContext::new(
        audio_tx,
        api_arc.clone(),
        db_arc,
        http_cache,
        signals.clone(),
        state,
        effect_handles.clone(),
    );

    load_persisted_settings(&context).await;
    context.audio.signals.monitor.set_enabled(true);

    let context_arc = Arc::new(context.clone());

    workers::spawn_sync_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_event_worker(context_arc.clone(), event_rx, shutdown_rx.clone());
    workers::spawn_bridge_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_settings_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_cache_worker(context_arc.clone(), shutdown_rx.clone());

    AUDIO_READY.notify_waiters();
    Ok(context)
}
