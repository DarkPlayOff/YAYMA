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
    if let Some(path) = ctx.core.track_cache.get_cover(&url).await {
        return Some(path.to_string_lossy().into_owned());
    }
    let cache = &ctx.core.http_cache;
    cache
        .get_file(&url)
        .await
        .ok()
        .map(|p| p.to_string_lossy().into_owned())
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

pub async fn get_track_cache_size(ctx: &AppContext) -> i64 {
    ctx.core.track_cache.get_size().await.unwrap_or(0)
}

pub async fn clear_track_cache(ctx: &AppContext) {
    let _ = ctx.core.track_cache.clear().await;
}

static INIT_DB: tokio::sync::OnceCell<Option<tokio::sync::Mutex<crate::storage::db::AppDatabase>>> = tokio::sync::OnceCell::const_new();

async fn get_init_db() -> Option<&'static tokio::sync::Mutex<crate::storage::db::AppDatabase>> {
    INIT_DB.get_or_init(|| async {
        crate::storage::db::AppDatabase::init(crate::app::get_data_dir())
            .await
            .ok()
            .map(tokio::sync::Mutex::new)
    })
    .await
    .as_ref()
}

pub fn is_discord_rpc_enabled(ctx: &AppContext) -> bool {
    ctx.audio.signals.discord_rpc.get()
}

pub async fn set_discord_rpc_enabled(ctx: &AppContext, enabled: bool) {
    ctx.audio.signals.discord_rpc.set(enabled);
    let mut db = ctx.core.db.lock().await;
    let _ = db.save_setting("discord_rpc", &enabled).await;
}

pub async fn is_custom_titlebar_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("custom_titlebar").await.unwrap_or(Some(true)).unwrap_or(true)
}

pub async fn is_custom_titlebar_enabled_init() -> bool {
    if let Some(db_mutex) = get_init_db().await {
        let mut db = db_mutex.lock().await;
        db.load_setting("custom_titlebar").await.unwrap_or(Some(true)).unwrap_or(true)
    } else {
        true
    }
}

pub async fn set_custom_titlebar_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    let _ = db.save_setting("custom_titlebar", &enabled).await;
}

pub async fn is_auto_hide_navbar_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("auto_hide_navbar").await.unwrap_or(Some(false)).unwrap_or(false)
}

pub async fn is_auto_hide_navbar_enabled_init() -> bool {
    if let Some(db_mutex) = get_init_db().await {
        let mut db = db_mutex.lock().await;
        db.load_setting("auto_hide_navbar").await.unwrap_or(Some(false)).unwrap_or(false)
    } else {
        false
    }
}

pub async fn set_auto_hide_navbar_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    let _ = db.save_setting("auto_hide_navbar", &enabled).await;
}

pub async fn is_close_to_tray_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("close_to_tray").await.unwrap_or(Some(true)).unwrap_or(true)
}

pub async fn is_close_to_tray_enabled_init() -> bool {
    if let Some(db_mutex) = get_init_db().await {
        let mut db = db_mutex.lock().await;
        db.load_setting("close_to_tray").await.unwrap_or(Some(true)).unwrap_or(true)
    } else {
        true
    }
}

pub async fn set_close_to_tray_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    let _ = db.save_setting("close_to_tray", &enabled).await;
}

fn extract_display_name(raw: &str) -> String {
    if let Some(pos) = raw.find(" (") {
        let inner = &raw[pos + 2..];
        if let Some(stripped) = inner.strip_suffix(')') {
            return stripped.to_string();
        }
    }
    raw.to_string()
}

pub fn get_audio_devices(_ctx: &AppContext) -> Vec<String> {
    use std::collections::HashMap;

    #[cfg(target_os = "windows")]
    let raw_names: Vec<String> = crate::audio::util::get_windows_full_device_names();

    #[cfg(not(target_os = "windows"))]
    let raw_names: Vec<String> = {
        use rodio::cpal::traits::HostTrait;
        use rodio::DeviceTrait;
        let host = rodio::cpal::default_host();
        host.output_devices()
            .map(|devs| {
                devs.filter_map(|d| d.description().ok().map(|desc| desc.name().to_string()))
                    .collect()
            })
            .unwrap_or_default()
    };

    let mut display_names: Vec<String> =
        raw_names.iter().map(|n| extract_display_name(n)).collect();
    display_names.sort();

    let mut counts: HashMap<String, usize> = HashMap::default();
    for name in &display_names {
        *counts.entry(name.clone()).or_insert(0) += 1;
    }
    let mut seen: HashMap<String, usize> = HashMap::default();
    let mut result = Vec::with_capacity(display_names.len());
    for name in display_names {
        let total = counts.get(&name).copied().unwrap_or(1);
        let idx = seen.entry(name.clone()).or_insert(0);
        *idx += 1;
        if total > 1 {
            result.push(format!("{} ({})", name, idx));
        } else {
            result.push(name);
        }
    }
    result
}

pub async fn set_audio_device(ctx: &AppContext, device_name: String) {
    let device = if device_name.is_empty() {
        None
    } else {
        Some(device_name)
    };
    let tx = ctx.audio.tx.clone();
    let _ = tx
        .send(crate::audio::commands::AudioMessage::SetAudioDevice(device))
        .await;
}
