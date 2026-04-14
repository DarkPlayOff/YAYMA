use crate::api::models::{PlaybackProgressDto, PlaybackState, SimpleTrackDto};
use crate::app::AppContext;
use crate::frb_generated::StreamSink;
use crate::app::logic::simple as logic;

#[derive(Debug, Clone)]
pub enum AppEvent {
    PlaybackStateChanged(PlaybackState),
    PlaybackProgress(PlaybackProgressDto),
    VibeTick(Vec<f32>),
    LikedTracksChanged(Vec<SimpleTrackDto>),
    AuthStatusChanged(bool),
    Notification(String, String), // Title, Message
    Error(String),
}

pub fn get_app_version() -> String {
    logic::get_app_version()
}

pub fn app_event_stream(ctx: &AppContext, sink: StreamSink<AppEvent>) {
    logic::app_event_stream(ctx, sink)
}

pub async fn get_cached_image_path(url: String) -> Option<String> {
    logic::get_cached_image_path(url).await
}

pub async fn prune_expired_cache() {
    logic::prune_expired_cache().await
}
