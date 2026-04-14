use crate::app::context::AppContext;
use crate::app::settings::load_persisted_settings;
use crate::app::workers;
use crate::app::{APP_DB, AUDIO_READY};
use crate::audio::system::AudioSystem;
use crate::db::AppDatabase;
use crate::http::ApiService;
use parking_lot::Mutex;
use std::sync::Arc;

/// Полный цикл инициализации приложения
pub async fn initialize_app(
    api: ApiService,
) -> Result<AppContext, Box<dyn std::error::Error + Send + Sync>> {
    ensure_database_initialized()?;
    initialize_services(api).await
}

/// Инициализация базовой инфраструктуры (логирование, паник-хук, БД)
/// Вызывается один раз при старте FRB
pub fn initialize_infrastructure() {
    static ONCE: std::sync::Once = std::sync::Once::new();

    ONCE.call_once(|| {
        flutter_rust_bridge::setup_default_user_utils();
        crate::util::hook::set_panic_hook();
        let _ = crate::util::log::initialize_logging();

        if let Err(e) = ensure_database_initialized() {
            eprintln!("Failed to initialize database: {e}");
        }
    });
}

fn ensure_database_initialized() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if APP_DB.get().is_none() {
        let db = AppDatabase::init()?;
        let _ = APP_DB.set(Arc::new(Mutex::new(db)));
    }
    Ok(())
}

async fn initialize_services(
    api: ApiService,
) -> Result<AppContext, Box<dyn std::error::Error + Send + Sync>> {
    let api_arc = Arc::new(api);
    let (event_tx, event_rx) = flume::unbounded();

    let (audio_tx, signals, state, effect_handles) =
        AudioSystem::spawn(event_tx.clone(), api_arc.clone()).await?;

    let db_arc = APP_DB
        .get()
        .ok_or_else(|| "Database not initialized".to_string())?
        .clone();

    let (context, shutdown_rx) = AppContext::new(
        audio_tx,
        api_arc.clone(),
        db_arc,
        signals.clone(),
        state,
        effect_handles.clone(),
    );

    load_persisted_settings(&context).await;
    context.signals.monitor.set_enabled(true);

    let context_arc = Arc::new(context.clone());

    workers::spawn_sync_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_event_worker(context_arc.clone(), event_rx, shutdown_rx.clone());
    workers::spawn_bridge_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_settings_worker(context_arc.clone(), shutdown_rx.clone());
    workers::spawn_cache_worker(shutdown_rx.clone());

    AUDIO_READY.notify_waiters();
    Ok(context)
}
