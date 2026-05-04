use crate::api::simple::AppEvent;
use crate::app::AppContext;
use crate::frb_generated::StreamSink;

pub fn get_app_version() -> String {
    env!("PUBSPEC_VERSION").to_string()
}

pub fn app_event_stream(ctx: &AppContext, sink: StreamSink<AppEvent>) {
    let _ = ctx.event_sink.set(sink);
}

pub async fn get_cached_image_path(url: String) -> Option<String> {
    let cache = crate::storage::cache::get_http_cache().await;
    cache
        .get_file(&url)
        .await
        .ok()
        .map(|p| p.to_string_lossy().to_string())
}

pub async fn prune_expired_cache() {
    let cache = crate::storage::cache::get_http_cache().await;
    let _ = cache.prune_expired().await;
}

pub async fn get_cache_size() -> i64 {
    let cache = crate::storage::cache::get_http_cache().await;
    cache.get_size().await.unwrap_or(0)
}

pub async fn clear_cache() {
    let cache = crate::storage::cache::get_http_cache().await;
    let _ = cache.clear().await;
}

pub fn is_discord_rpc_enabled(ctx: &AppContext) -> bool {
    ctx.signals.discord_rpc.get()
}

pub fn set_discord_rpc_enabled(ctx: &AppContext, enabled: bool) {
    ctx.signals.discord_rpc.set(enabled);
    let db = ctx.db.lock();
    let _ = db.save_discord_rpc(enabled);
}
