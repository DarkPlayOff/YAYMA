use crate::api::models::{
    InitialSettingsDto, PlaybackProgressDto, PlaybackState, SimpleTrackDto, UserAccountDto,
};
use crate::app::AppContext;
use crate::app::settings::parse_setting;
use crate::frb_generated::StreamSink;
use std::collections::HashMap;

#[derive(Debug, Clone)]
// `PlaybackState` is large, but events are sent one at a time through a channel
// and consumed immediately; boxing would add an allocation per progress tick.
#[expect(
    clippy::large_enum_variant,
    reason = "events cross a channel one at a time; boxing adds per-event allocation"
)]
pub enum AppEvent {
    PlaybackStateChanged(PlaybackState),
    PlaybackProgress(PlaybackProgressDto),
    VibeTick([f32; 26]),
    LikedTracksChanged(Vec<SimpleTrackDto>),
    AuthStatusChanged(bool),
    AccountUpdated(UserAccountDto),
    Notification(String, String), // Title, Message
    Error(String),
    TrackDownloadStarted(String),
    TrackDownloadFinished(String),
    TrackDownloadFailed(String, String),
}

pub fn init_app_infrastructure(base_path: Option<String>) {
    crate::app::initialize_infrastructure(base_path)
}

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

pub async fn get_initial_settings() -> InitialSettingsDto {
    let Ok(database) = crate::app::get_database().await else {
        return InitialSettingsDto::default();
    };
    let mut db = database.lock().await;
    let settings = db.load_all_settings().await.unwrap_or_default();
    InitialSettingsDto {
        custom_titlebar: parse_setting(&settings, "custom_titlebar").unwrap_or(true),
        auto_hide_navbar: parse_setting(&settings, "auto_hide_navbar").unwrap_or(false),
        close_to_tray: parse_setting(&settings, "close_to_tray").unwrap_or(true),
        vibe_animation_enabled: parse_setting(&settings, "vibe_animation_enabled").unwrap_or(true),
        vibe_render_scale: parse_setting::<f64>(&settings, "vibe_render_scale")
            .unwrap_or(0.50)
            .clamp(0.25, 0.50),
        blur_effects_enabled: parse_setting(&settings, "blur_effects_enabled").unwrap_or(true),
        crossfade_enabled: parse_setting::<bool>(&settings, "crossfade_enabled").unwrap_or(true),
        ai_content_reduction: parse_setting::<bool>(&settings, "ai_content_reduction")
            .unwrap_or(false),
    }
}

pub fn is_discord_rpc_enabled(ctx: &AppContext) -> bool {
    ctx.audio.signals.discord_rpc.get()
}

pub async fn set_discord_rpc_enabled(ctx: &AppContext, enabled: bool) {
    ctx.audio.signals.discord_rpc.set(enabled);
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("discord_rpc", &enabled).await {
        tracing::error!(key = "discord_rpc", error = ?e, "save_setting_failed");
    }
}

pub async fn is_custom_titlebar_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("custom_titlebar")
        .await
        .unwrap_or(Some(true))
        .unwrap_or(true)
}

pub async fn set_custom_titlebar_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("custom_titlebar", &enabled).await {
        tracing::error!(key = "custom_titlebar", error = ?e, "save_setting_failed");
    }
}

pub async fn is_auto_hide_navbar_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("auto_hide_navbar")
        .await
        .unwrap_or(Some(false))
        .unwrap_or(false)
}

pub async fn set_auto_hide_navbar_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("auto_hide_navbar", &enabled).await {
        tracing::error!(key = "auto_hide_navbar", error = ?e, "save_setting_failed");
    }
}

pub async fn is_close_to_tray_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("close_to_tray")
        .await
        .unwrap_or(Some(true))
        .unwrap_or(true)
}

pub async fn set_close_to_tray_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("close_to_tray", &enabled).await {
        tracing::error!(key = "close_to_tray", error = ?e, "save_setting_failed");
    }
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
    #[cfg(target_os = "windows")]
    let raw_names: Vec<String> = crate::audio::util::get_windows_full_device_names();

    #[cfg(not(target_os = "windows"))]
    let raw_names: Vec<String> = {
        use rodio::DeviceTrait;
        use rodio::cpal::traits::HostTrait;
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

pub async fn is_update_check_enabled(ctx: &AppContext) -> bool {
    let mut db = ctx.core.db.lock().await;
    db.load_setting("update_check")
        .await
        .unwrap_or(Some(true))
        .unwrap_or(true)
}

pub async fn set_update_check_enabled(ctx: &AppContext, enabled: bool) {
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("update_check", &enabled).await {
        tracing::error!(key = "update_check", error = ?e, "save_setting_failed");
    }
}

pub async fn set_vibe_animation_enabled(ctx: &AppContext, enabled: bool) {
    // Read by the bridge worker: when the shader is disabled, VibeTick
    // computation is skipped entirely rather than just dropped on the Dart side.
    ctx.audio.signals.vibe_enabled.set(enabled);
    // The monitor only feeds the shader, so its band split can idle too.
    ctx.audio.signals.monitor.set_enabled(enabled);
    let _ = ctx
        .core
        .db
        .lock()
        .await
        .save_setting("vibe_animation_enabled", &enabled)
        .await;
}

pub async fn set_vibe_render_scale(ctx: &AppContext, scale: f64) {
    let scale = scale.clamp(0.25, 0.50);
    let _ = ctx
        .core
        .db
        .lock()
        .await
        .save_setting("vibe_render_scale", &scale)
        .await;
}

pub async fn set_blur_effects_enabled(ctx: &AppContext, enabled: bool) {
    let _ = ctx
        .core
        .db
        .lock()
        .await
        .save_setting("blur_effects_enabled", &enabled)
        .await;
}

/// Enables or disables crossfade (on = fixed-length overlap, off = strict
/// gapless). Applied immediately through the audio signals the controller's
/// monitor reads; persisted for the next launch.
pub async fn set_crossfade(ctx: &AppContext, enabled: bool) {
    let ms = if enabled {
        crate::audio::signals::USER_CROSSFADE_MS
    } else {
        0
    };
    ctx.audio.signals.crossfade_ms.set(ms);
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("crossfade_enabled", &enabled).await {
        tracing::error!(key = "crossfade_enabled", error = ?e, "save_setting_failed");
    }
}

/// Enables or disables "Меньше ИИ" (fewer AI-generated tracks in the
/// recommendations): mirrors the value to the account, applies it to the next
/// rotor session, and persists it for the next launch.
pub async fn set_ai_content_reduction(ctx: &AppContext, enabled: bool) {
    ctx.core.api.set_ai_reduction(enabled);
    if let Err(e) = ctx.core.api.set_ai_reduction_remote(enabled).await {
        tracing::warn!(error = ?e, "ai_reduction_sync_failed");
    }
    let mut db = ctx.core.db.lock().await;
    if let Err(e) = db.save_setting("ai_content_reduction", &enabled).await {
        tracing::error!(key = "ai_content_reduction", error = ?e, "save_setting_failed");
    }
}

/// Pulls "Меньше ИИ" from the account so a change made in an official client
/// shows up here too. Falls back to the cached value when offline.
pub async fn sync_ai_content_reduction(ctx: &AppContext) -> bool {
    let cached = {
        let mut db = ctx.core.db.lock().await;
        db.load_setting("ai_content_reduction")
            .await
            .ok()
            .flatten()
            .unwrap_or(false)
    };
    let enabled = match ctx.core.api.get_ai_reduction_remote().await {
        Ok(enabled) => enabled,
        Err(e) => {
            tracing::warn!(error = ?e, "ai_reduction_fetch_failed");
            return cached;
        }
    };
    ctx.core.api.set_ai_reduction(enabled);
    if enabled != cached {
        let mut db = ctx.core.db.lock().await;
        if let Err(e) = db.save_setting("ai_content_reduction", &enabled).await {
            tracing::error!(key = "ai_content_reduction", error = ?e, "save_setting_failed");
        }
    }
    enabled
}

/// Forwards a Dart-side log message into the Rust tracing pipeline, so UI
/// errors land in the same rotated file log. Levels: 0=debug, 1=info,
/// 2=warn, 3=error; unknown levels fall back to info.
pub async fn log_from_dart(level: u8, message: String) {
    match level {
        0 => tracing::debug!(source = "dart", "{message}"),
        1 => tracing::info!(source = "dart", "{message}"),
        2 => tracing::warn!(source = "dart", "{message}"),
        3 => tracing::error!(source = "dart", "{message}"),
        _ => tracing::info!(source = "dart", "{message}"),
    }
}
