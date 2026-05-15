use crate::api::simple::AppEvent;
use crate::app::AppContext;
use crate::frb_generated::StreamSink;

pub fn get_app_version() -> String {
    env!("PUBSPEC_VERSION").to_string()
}

pub fn app_event_stream(ctx: &AppContext, sink: StreamSink<AppEvent>) {
    let _ = ctx.system.event_sink.set(sink);
}

pub async fn get_cached_image_path(ctx: &AppContext, url: String) -> Option<String> {
    let cache = &ctx.core.http_cache;
    cache
        .get_file(&url)
        .await
        .ok()
        .map(|p| p.to_string_lossy().to_string())
}

pub async fn prune_expired_cache(ctx: &AppContext) {
    let cache = &ctx.core.http_cache;
    let _ = cache.prune_expired().await;
}

pub async fn get_cache_size(ctx: &AppContext) -> i64 {
    let cache = &ctx.core.http_cache;
    cache.get_size().await.unwrap_or(0)
}

pub async fn clear_cache(ctx: &AppContext) {
    let cache = &ctx.core.http_cache;
    let _ = cache.clear().await;
}

pub fn is_discord_rpc_enabled(ctx: &AppContext) -> bool {
    ctx.audio.signals.discord_rpc.get()
}

pub fn set_discord_rpc_enabled(ctx: &AppContext, enabled: bool) {
    ctx.audio.signals.discord_rpc.set(enabled);
    let db = ctx.core.db.lock();
    let _ = db.save_discord_rpc(enabled);
}

pub fn is_custom_titlebar_enabled(ctx: &AppContext) -> bool {
    let db = ctx.core.db.lock();
    db.load_custom_titlebar().unwrap_or(false)
}

pub fn is_custom_titlebar_enabled_sync() -> bool {
    if let Ok(db) = crate::storage::db::AppDatabase::init(crate::app::get_data_dir()) {
        db.load_custom_titlebar().unwrap_or(true)
    } else {
        true
    }
}

pub fn set_custom_titlebar_enabled(ctx: &AppContext, enabled: bool) {
    let db = ctx.core.db.lock();
    let _ = db.save_custom_titlebar(enabled);
}

pub fn is_auto_hide_navbar_enabled(ctx: &AppContext) -> bool {
    let db = ctx.core.db.lock();
    db.load_auto_hide_navbar().unwrap_or(true)
}

pub fn is_auto_hide_navbar_enabled_sync() -> bool {
    if let Ok(db) = crate::storage::db::AppDatabase::init(crate::app::get_data_dir()) {
        db.load_auto_hide_navbar().unwrap_or(true)
    } else {
        true
    }
}

pub fn set_auto_hide_navbar_enabled(ctx: &AppContext, enabled: bool) {
    let db = ctx.core.db.lock();
    let _ = db.save_auto_hide_navbar(enabled);
}
