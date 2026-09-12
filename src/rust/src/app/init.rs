use crate::app::AUDIO_READY;
use crate::app::context::AppContext;
use crate::app::settings::load_persisted_settings;
use crate::app::workers;
use crate::audio::system::AudioSystem;
use crate::db::AppDatabase;
use crate::http::ApiService;
use crate::storage::cache::{HttpCache, TrackCache};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::OnceLock;
use tokio::sync::Mutex;

static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();
static DATABASE: tokio::sync::OnceCell<Arc<Mutex<AppDatabase>>> =
    tokio::sync::OnceCell::const_new();

pub async fn get_database()
-> Result<Arc<Mutex<AppDatabase>>, Box<dyn std::error::Error + Send + Sync>> {
    let database = DATABASE
        .get_or_try_init(|| async {
            Ok::<_, Box<dyn std::error::Error + Send + Sync>>(Arc::new(Mutex::new(
                AppDatabase::init(DATA_DIR.get().cloned()).await?,
            )))
        })
        .await?;
    Ok(database.clone())
}

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
    let event_sink: Arc<
        tokio::sync::OnceCell<crate::frb_generated::StreamSink<crate::api::simple::AppEvent>>,
    > = Arc::new(tokio::sync::OnceCell::new());
    let error_reporter: Arc<dyn Fn(String) + Send + Sync> = {
        let event_sink = event_sink.clone();
        Arc::new(move |msg| {
            if let Some(sink) = event_sink.get() {
                let _ = sink.add(crate::api::simple::AppEvent::Error(msg));
            }
        })
    };

    let db_arc = get_database().await?;
    let http_cache = Arc::new(HttpCache::new(db_arc.clone(), DATA_DIR.get().cloned()));
    let track_cache = Arc::new(TrackCache::new(DATA_DIR.get().cloned()));
    let _ = track_cache.init().await;

    let (audio_tx, signals, state, effect_handles) = AudioSystem::spawn(
        error_reporter,
        api_arc.clone(),
        db_arc.clone(),
        http_cache.clone(),
        track_cache.clone(),
    )
    .await?;

    let (context, shutdown_rx) = AppContext::new(
        audio_tx,
        api_arc.clone(),
        db_arc,
        http_cache,
        track_cache,
        signals.clone(),
        state,
        effect_handles.clone(),
        event_sink,
    );

    load_persisted_settings(&context).await;
    context.audio.signals.monitor.set_enabled(true);

    workers::spawn_sync_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_bridge_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_settings_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_cache_worker(context.clone(), shutdown_rx.clone());

    #[cfg(target_os = "windows")]
    crate::audio::taskbar::init(context.clone(), shutdown_rx.clone());

    AUDIO_READY.notify_waiters();
    Ok(context)
}
