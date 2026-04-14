use crate::api::models::{
    AlbumDetailsDto, AppError, ArtistDetailsDto, PlaylistDetailsDto, SearchResultsDto,
    StationCategoryDto, TrackDetailsDto,
};
use crate::app::AppContext;
use crate::app::logic::content as logic;

pub async fn search(ctx: &AppContext, query: String) -> Option<SearchResultsDto> {
    logic::search(ctx, query).await
}

pub async fn set_download_path(ctx: &AppContext, path: String) -> Result<(), AppError> {
    logic::set_download_path(ctx, path).await
}

pub async fn get_download_path(ctx: &AppContext) -> Result<Option<String>, AppError> {
    logic::get_download_path(ctx).await
}

pub async fn download_track(ctx: &AppContext, track_id: String) -> Result<String, AppError> {
    logic::download_track(ctx, track_id).await
}

pub async fn get_track_details(
    ctx: &AppContext,
    track_id: String,
) -> Result<TrackDetailsDto, AppError> {
    logic::get_track_details(ctx, track_id).await
}

pub async fn get_album_details(ctx: &AppContext, album_id: u32) -> Option<AlbumDetailsDto> {
    logic::get_album_details(ctx, album_id).await
}

pub async fn get_artist_details(
    ctx: &AppContext,
    artist_id: String,
    page: u32,
    page_size: u32,
) -> Option<ArtistDetailsDto> {
    logic::get_artist_details(ctx, artist_id, page, page_size).await
}

pub async fn get_playlist_details(
    ctx: &AppContext,
    uid: i64,
    kind: u32,
    query: Option<String>,
) -> Option<PlaylistDetailsDto> {
    logic::get_playlist_details(ctx, uid, kind, query).await
}

pub async fn fetch_wave_stations(ctx: &AppContext) -> Vec<StationCategoryDto> {
    logic::fetch_wave_stations(ctx).await
}

pub async fn get_lyrics(ctx: &AppContext, track_id: String) -> Option<String> {
    logic::get_lyrics(ctx, track_id).await
}
