use crate::api::models::{SimplePlaylistDto, SimpleTrackDto};
use crate::app::AppContext;
use crate::app::logic::library as logic;
use crate::frb_generated::StreamSink;

pub async fn toggle_like(ctx: &AppContext, track_id: String) {
    logic::toggle_like(ctx, track_id).await
}

pub async fn toggle_dislike(ctx: &AppContext, track_id: String) {
    logic::toggle_dislike(ctx, track_id).await
}

pub async fn upload_user_track(
    ctx: &AppContext,
    file_path: String,
    playlist_kind: Option<u32>,
) -> bool {
    logic::upload_user_track(ctx, file_path, playlist_kind).await
}

pub async fn get_playlists(ctx: &AppContext) -> Vec<SimplePlaylistDto> {
    logic::get_playlists(ctx).await
}

pub async fn add_track_to_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    logic::add_track_to_playlist(ctx, kind, track_id, album_id).await
}

pub async fn remove_track_from_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    logic::remove_track_from_playlist(ctx, kind, track_id, album_id).await
}

pub async fn create_playlist(ctx: &AppContext, title: String, is_public: bool) -> bool {
    logic::create_playlist(ctx, title, is_public).await
}

pub async fn delete_playlist(ctx: &AppContext, kind: u32) -> bool {
    logic::delete_playlist(ctx, kind).await
}

pub async fn rename_playlist(ctx: &AppContext, kind: u32, new_title: String) -> bool {
    logic::rename_playlist(ctx, kind, new_title).await
}

pub async fn set_playlist_visibility(ctx: &AppContext, kind: u32, is_public: bool) -> bool {
    logic::set_playlist_visibility(ctx, kind, is_public).await
}

pub async fn move_track_in_playlist(
    ctx: &AppContext,
    kind: u32,
    from_index: u32,
    to_index: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    logic::move_track_in_playlist(ctx, kind, from_index, to_index, track_id, album_id).await
}

pub async fn liked_tracks_stream(
    ctx: &AppContext,
    sink: StreamSink<Vec<SimpleTrackDto>>,
    query: Option<String>,
) {
    logic::liked_tracks_stream(ctx, sink, query).await
}
