use crate::app::AUDIO_READY;
use crate::app::context::{AppAudioContext, AppContext, AppCoreContext};
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

/// The live session's context. `clear_token` is the FRB logout and takes no
/// context argument, so this static is its only handle to the stack it must
/// tear down. One session is live at a time: login overwrites, logout takes.
static CURRENT: parking_lot::RwLock<Option<AppContext>> = parking_lot::RwLock::new(None);

/// Takes the live context for teardown. Only the logout path may call this.
pub fn take_context() -> Option<AppContext> {
    CURRENT.write().take()
}

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

/// Initialize base infrastructure (panic hook, DB, logging)
/// Called once at FRB startup (with `None`) and again from Dart right after,
/// with the real data dir. The log file lives in the data dir, so logging
/// starts only on that second call; before it, the panic hook is the only
/// reporter.
pub fn initialize_infrastructure(base_path: Option<String>) {
    if let Some(path) = &base_path {
        let p = PathBuf::from(path);
        std::fs::create_dir_all(&p).ok();
        DATA_DIR.set(p).ok();
    }

    static INIT_ONCE: std::sync::Once = std::sync::Once::new();
    INIT_ONCE.call_once(|| {
        flutter_rust_bridge::setup_default_user_utils();
        crate::util::hook::set_panic_hook();
    });

    static LOG_ONCE: std::sync::Once = std::sync::Once::new();
    if base_path.is_some() {
        LOG_ONCE.call_once(|| {
            let _ = crate::util::log::initialize_logging();
        });
    }
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

    // Created here (not in AppContext::new) so the audio stack can be wired
    // to the same shutdown channel the context will hold.
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

    let (audio_tx, signals, state, effect_handles) = AudioSystem::spawn(
        error_reporter,
        api_arc.clone(),
        db_arc.clone(),
        http_cache.clone(),
        track_cache.clone(),
        shutdown_rx.clone(),
    )
    .await?;

    let context = AppContext::new(
        AppAudioContext {
            tx: audio_tx,
            signals,
            state,
            effect_handles,
        },
        AppCoreContext {
            api: api_arc.clone(),
            db: db_arc,
            http_cache,
            track_cache,
        },
        event_sink,
        shutdown_tx,
    );
    *CURRENT.write() = Some(context.clone());

    load_persisted_settings(&context).await;
    // The monitor feeds only the vibe shader: keep it off while the shader is
    // disabled instead of running the band split for every audio block.
    context
        .audio
        .signals
        .monitor
        .set_enabled(context.audio.signals.vibe_enabled.get());

    workers::spawn_sync_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_bridge_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_settings_worker(context.clone(), shutdown_rx.clone());
    workers::spawn_cache_worker(context.clone(), shutdown_rx.clone());

    #[cfg(target_os = "windows")]
    crate::audio::taskbar::init(context.clone(), shutdown_rx.clone());

    // macOS requires the manager to live on the main thread (see
    // app/hotkeys.rs); the app doesn't ship for macOS, so gate it out.
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    crate::app::hotkeys::init(context.clone(), shutdown_rx.clone()).await;

    AUDIO_READY.notify_waiters();
    Ok(context)
}
