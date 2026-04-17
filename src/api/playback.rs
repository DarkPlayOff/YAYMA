use crate::api::models::SimpleTrackDto;
pub use crate::api::models::{PlaybackState, RepeatModeDto};
use crate::app::AppContext;
use crate::app::logic::playback as logic;

pub fn get_playback_state(
    signals: &crate::audio::signals::AudioSignals,
    liked_ids: &std::collections::HashSet<String>,
    disliked_ids: &std::collections::HashSet<String>,
) -> PlaybackState {
    logic::get_playback_state(signals, liked_ids, disliked_ids)
}

pub async fn toggle_play_pause(ctx: &AppContext) {
    logic::toggle_play_pause(ctx).await
}

pub async fn play_next(ctx: &AppContext) {
    logic::play_next(ctx).await
}

pub async fn play_prev(ctx: &AppContext) {
    logic::play_prev(ctx).await
}

pub async fn seek(ctx: &AppContext, position_ms: u32) {
    logic::seek(ctx, position_ms).await
}

pub async fn set_volume(ctx: &AppContext, volume: u8) {
    logic::set_volume(ctx, volume).await
}

pub async fn toggle_shuffle(ctx: &AppContext) {
    logic::toggle_shuffle(ctx).await
}

pub async fn toggle_repeat_mode(ctx: &AppContext) {
    logic::toggle_repeat_mode(ctx).await
}

pub async fn stop(ctx: &AppContext) {
    logic::stop(ctx).await
}

pub async fn get_queue(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    logic::get_queue(ctx).await
}

pub async fn get_history(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    logic::get_history(ctx).await
}

pub async fn play_track(ctx: &AppContext, track_id: String) {
    logic::play_track(ctx, track_id).await
}

pub async fn restore_and_play(
    ctx: &AppContext,
    track_id: String,
    position_ms: u32,
    is_playing: bool,
) {
    logic::restore_and_play(ctx, track_id, position_ms, is_playing).await
}

pub async fn play_playlist(ctx: &AppContext, uid: String, kind: u32) {
    logic::play_playlist(ctx, uid, kind).await
}

pub async fn play_album(ctx: &AppContext, album_id: u32) {
    logic::play_album(ctx, album_id).await
}

pub async fn play_album_track(ctx: &AppContext, album_id: u32, track_id: String) {
    logic::play_album_track(ctx, album_id, track_id).await
}

pub async fn play_playlist_track(ctx: &AppContext, uid: String, kind: u32, track_id: String) {
    logic::play_playlist_track(ctx, uid, kind, track_id).await
}

pub async fn play_liked_track(ctx: &AppContext, track_id: String) {
    logic::play_liked_track(ctx, track_id).await
}

pub async fn start_wave(ctx: &AppContext, seeds: Vec<String>) {
    logic::start_wave(ctx, seeds).await
}
