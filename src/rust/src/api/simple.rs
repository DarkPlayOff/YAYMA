use crate::api::models::{PlaybackProgressDto, PlaybackState, SimpleTrackDto, UserAccountDto};
use crate::app::AppContext;
use crate::app::logic::simple as logic;
use crate::frb_generated::StreamSink;

#[derive(Debug, Clone)]
pub enum AppEvent {
    PlaybackStateChanged(PlaybackState),
    PlaybackProgress(PlaybackProgressDto),
    VibeTick([f32; 26]),
    LikedTracksChanged(Vec<SimpleTrackDto>),
    AuthStatusChanged(bool),
    AccountUpdated(UserAccountDto),
    Notification(String, String), // Title, Message
    Error(String),
}

pub fn init_app_infrastructure(base_path: Option<String>) {
    crate::app::initialize_infrastructure(base_path)
}

pub fn get_app_version() -> String {
    logic::get_app_version()
}

pub fn app_event_stream(ctx: &AppContext, sink: StreamSink<AppEvent>) {
    logic::app_event_stream(ctx, sink)
}

pub async fn get_cached_image_path(ctx: &AppContext, url: String) -> Option<String> {
    logic::get_cached_image_path(ctx, url).await
}

pub async fn prune_expired_cache(ctx: &AppContext) {
    logic::prune_expired_cache(ctx).await
}

pub async fn get_cache_size(ctx: &AppContext) -> i64 {
    logic::get_cache_size(ctx).await
}

pub async fn clear_cache(ctx: &AppContext) {
    logic::clear_cache(ctx).await
}

pub fn is_discord_rpc_enabled(ctx: &AppContext) -> bool {
    logic::is_discord_rpc_enabled(ctx)
}

pub async fn set_discord_rpc_enabled(ctx: &AppContext, enabled: bool) {
    logic::set_discord_rpc_enabled(ctx, enabled).await;
}

pub async fn is_custom_titlebar_enabled(ctx: &AppContext) -> bool {
    logic::is_custom_titlebar_enabled(ctx).await
}

pub async fn is_custom_titlebar_enabled_init() -> bool {
    logic::is_custom_titlebar_enabled_init().await
}

pub async fn set_custom_titlebar_enabled(ctx: &AppContext, enabled: bool) {
    logic::set_custom_titlebar_enabled(ctx, enabled).await;
}

pub async fn is_auto_hide_navbar_enabled(ctx: &AppContext) -> bool {
    logic::is_auto_hide_navbar_enabled(ctx).await
}

pub async fn is_auto_hide_navbar_enabled_init() -> bool {
    logic::is_auto_hide_navbar_enabled_init().await
}

pub async fn set_auto_hide_navbar_enabled(ctx: &AppContext, enabled: bool) {
    logic::set_auto_hide_navbar_enabled(ctx, enabled).await;
}

pub async fn is_close_to_tray_enabled(ctx: &AppContext) -> bool {
    logic::is_close_to_tray_enabled(ctx).await
}

pub async fn is_close_to_tray_enabled_init() -> bool {
    logic::is_close_to_tray_enabled_init().await
}

pub async fn set_close_to_tray_enabled(ctx: &AppContext, enabled: bool) {
    logic::set_close_to_tray_enabled(ctx, enabled).await;
}

pub fn get_audio_devices(ctx: &AppContext) -> Vec<String> {
    logic::get_audio_devices(ctx)
}

pub async fn set_audio_device(ctx: &AppContext, device_name: String) {
    logic::set_audio_device(ctx, device_name).await;
}
