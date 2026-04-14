use crate::util::track::CleanId;
use serde::{Deserialize, Serialize};
pub use yandex_music::model::{album::Album, artist::Artist, playlist::Playlist, track::Track};

pub const COVER_SIZE_SMALL: &str = "200x200";
pub const COVER_SIZE_MEDIUM: &str = "400x400";
pub const COVER_SIZE_LARGE: &str = "1000x1000";

pub fn format_cover(uri: Option<String>, size: &str) -> Option<String> {
    uri.map(|s| {
        let s = s.replace("%%", size);
        if s.starts_with("//") {
            format!("https:{}", s)
        } else if !s.starts_with("http") {
            format!("https://{}", s)
        } else {
            s
        }
    })
}

#[flutter_rust_bridge::frb(ignore)]
fn get_any_cover(t: &Track) -> Option<String> {
    t.og_image
        .clone()
        .or_else(|| t.cover_uri.clone())
        .or_else(|| {
            t.albums
                .first()
                .and_then(|a| a.og_image.clone().or(a.cover_uri.clone()))
        })
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default, PartialEq, Eq)]
pub enum AudioQuality {
    Low, // lq
    #[default]
    Normal, // nq (192kbps)
    High, // lossless (320kbps or FLAC)
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchResultsDto {
    pub tracks: Vec<SimpleTrackDto>,
    pub albums: Vec<SimpleAlbumDto>,
    pub artists: Vec<SimpleArtistDto>,
    pub playlists: Vec<SimplePlaylistDto>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TrackArtistDto {
    pub id: String,
    pub name: String,
}

#[flutter_rust_bridge::frb(ignore)]
impl TrackArtistDto {
    pub fn from_yandex(a: &yandex_music::model::artist::Artist) -> Self {
        Self {
            id: a.id.as_ref().map(|id| id.to_string()).unwrap_or_default(),
            name: a.name.clone().unwrap_or_default(),
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SimpleTrackDto {
    pub id: String,
    pub title: String,
    pub version: Option<String>,
    pub artists: Vec<TrackArtistDto>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub duration_ms: u32,
    pub cover_url: Option<String>,
    pub is_liked: bool,
    pub is_disliked: bool,
}

#[flutter_rust_bridge::frb(ignore)]
impl SimpleTrackDto {
    pub fn from_yandex<S: std::hash::BuildHasher>(
        t: &Track,
        liked_ids: &std::collections::HashSet<String, S>,
        disliked_ids: &std::collections::HashSet<String, S>,
    ) -> Self {
        let track_id_base = t.id.to_base_id();
        let (album_title, album_id) = t
            .albums
            .first()
            .map(|a| (a.title.clone(), a.id.as_ref().map(|id| id.to_string())))
            .unwrap_or((None, None));

        Self {
            id: t.id.clone(),
            title: t.title.clone().unwrap_or_default(),
            version: t.version.clone(),
            artists: t.artists.iter().map(TrackArtistDto::from_yandex).collect(),
            album: album_title,
            album_id,
            duration_ms: t.duration.map(|d| d.as_millis() as u32).unwrap_or(0),
            cover_url: format_cover(get_any_cover(t), COVER_SIZE_MEDIUM),
            is_liked: liked_ids.contains(track_id_base),
            is_disliked: disliked_ids.contains(track_id_base),
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrackDetailsDto {
    pub id: String,
    pub title: String,
    pub artists: Vec<TrackArtistDto>,
    pub album: Option<String>,
    pub label: Option<String>,
    pub music_authors: Vec<String>,
    pub lyrics_authors: Vec<String>,
    pub source_platforms: Vec<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl TrackDetailsDto {
    pub fn from_yandex(mut t: Track) -> Self {
        let album_title = t.albums.get(0).and_then(|a| a.title.clone());

        // В yandex-music-rs лейбл находится в major.name
        let label = t.major.as_ref().map(|m| m.name.clone());

        // Авторы часто указываются как отдельные артисты или через метаданные,
        // но в упрощенном виде мы берем всех артистов
        let music_authors = t.artists.iter().filter_map(|a| a.name.clone()).collect();

        Self {
            id: t.id,
            title: t.title.take().unwrap_or_default(),
            artists: t.artists.iter().map(TrackArtistDto::from_yandex).collect(),
            album: album_title,
            label,
            music_authors,
            lyrics_authors: Vec::new(),
            source_platforms: Vec::new(),
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum RepeatModeDto {
    None,
    All,
    Single,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackState {
    pub is_playing: bool,
    pub volume: u8,
    pub is_muted: bool,
    pub repeat_mode: RepeatModeDto,
    pub is_shuffled: bool,
    pub queue_count: u32,
    pub queue_index: u32,
    pub current_track: Option<SimpleTrackDto>,
    pub current_wave_seeds: Vec<String>,
    pub codec: Option<String>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlaybackProgressDto {
    pub position_ms: u32,
    pub duration_ms: u32,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AlbumDetailsDto {
    pub id: String,
    pub title: String,
    pub artists: Vec<TrackArtistDto>,
    pub year: Option<i32>,
    pub cover_url: Option<String>,
    pub tracks: Vec<SimpleTrackDto>,
}

#[flutter_rust_bridge::frb(ignore)]
impl AlbumDetailsDto {
    pub fn from_yandex<S: std::hash::BuildHasher>(
        mut album: Album,
        liked_ids: &std::collections::HashSet<String, S>,
        disliked_ids: &std::collections::HashSet<String, S>,
    ) -> Self {
        let album_id = album.id.unwrap_or(0).to_string();
        let album_title = album.title.take().unwrap_or_default();
        let cover_url = format_cover(album.og_image.take(), "400x400");
        let year = album.year.map(|y| y as i32);
        let artists = album
            .artists
            .iter()
            .map(TrackArtistDto::from_yandex)
            .collect();

        let tracks = album
            .volumes
            .into_iter()
            .flatten()
            .map(|t| {
                let mut dto = SimpleTrackDto::from_yandex(&t, liked_ids, disliked_ids);
                dto.album = Some(album_title.clone());
                dto.album_id = Some(album_id.clone());
                dto
            })
            .collect();

        Self {
            id: album_id,
            title: album_title,
            artists,
            year,
            cover_url,
            tracks,
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ArtistDetailsDto {
    pub id: String,
    pub name: String,
    pub cover_url: Option<String>,
    pub tracks: Vec<SimpleTrackDto>,
    pub total_tracks: u32,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SimpleAlbumDto {
    pub id: String,
    pub title: String,
    pub artists: Vec<TrackArtistDto>,
    pub year: Option<i32>,
    pub cover_url: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl SimpleAlbumDto {
    pub fn from_yandex(mut album: yandex_music::model::album::Album) -> Self {
        Self {
            id: album.id.unwrap_or(0).to_string(),
            title: album.title.take().unwrap_or_default(),
            artists: album
                .artists
                .iter()
                .map(TrackArtistDto::from_yandex)
                .collect(),
            cover_url: format_cover(album.og_image.take(), "400x400"),
            year: album.year.map(|y| y as i32),
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SimpleArtistDto {
    pub id: String,
    pub name: String,
    pub cover_url: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl SimpleArtistDto {
    pub fn from_yandex(mut artist: Artist) -> Self {
        Self {
            id: artist.id.take().unwrap_or_default(),
            name: artist.name.take().unwrap_or_default(),
            cover_url: format_cover(artist.cover.and_then(|mut c| c.uri.take()), "400x400"),
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaylistDetailsDto {
    pub kind: u32,
    pub uid: i64,
    pub title: String,
    pub cover_url: Option<String>,
    pub tracks: Vec<SimpleTrackDto>,
    pub track_count: u32,
    pub is_public: bool,
}

#[flutter_rust_bridge::frb(ignore)]
impl PlaylistDetailsDto {
    pub fn from_yandex(mut playlist: Playlist) -> Self {
        let cover_url = format_cover(playlist.cover.uri.take(), "400x400");
        let title = std::mem::take(&mut playlist.title);
        let track_count = playlist.track_count;
        let is_public = format!("{:?}", playlist.visibility)
            .to_lowercase()
            .contains("public");

        Self {
            kind: playlist.kind,
            uid: playlist.uid as i64,
            title,
            cover_url,
            tracks: Vec::new(),
            track_count,
            is_public,
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SimplePlaylistDto {
    pub kind: u32,
    pub uid: i64,
    pub title: String,
    pub cover_url: Option<String>,
    pub track_count: u32,
    pub is_public: bool,
}

#[flutter_rust_bridge::frb(ignore)]
impl SimplePlaylistDto {
    pub fn from_yandex(mut playlist: Playlist) -> Self {
        let is_public = format!("{:?}", playlist.visibility)
            .to_lowercase()
            .contains("public");
        Self {
            kind: playlist.kind,
            uid: playlist.uid as i64,
            title: std::mem::take(&mut playlist.title),
            cover_url: format_cover(playlist.cover.uri.take(), "400x400"),
            track_count: playlist.track_count,
            is_public,
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SavedStateDto {
    pub track_id: String,
    pub position_ms: u32,
    pub is_playing: bool,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct StationCategoryDto {
    pub title: String,
    pub items: Vec<StationItemDto>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct StationItemDto {
    pub label: String,
    pub seed: String,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UserAccountDto {
    pub uid: i64,
    pub login: String,
    pub full_name: Option<String>,
    pub display_name: Option<String>,
    pub has_plus: bool,
    pub avatar_url: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl UserAccountDto {
    pub fn from_yandex(
        status: yandex_music::model::account::status::AccountStatus,
        avatar_url: Option<String>,
    ) -> Self {
        Self {
            uid: status.account.uid.unwrap_or(0) as i64,
            login: status.account.login.unwrap_or_default(),
            full_name: status.account.full_name,
            display_name: status.account.display_name,
            has_plus: status.plus.has_plus,
            avatar_url,
        }
    }
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BandDto {
    pub frequency: f32,
    pub gain_db: f32,
    pub index: u32,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EqualizerDto {
    pub enabled: bool,
    pub bands: Vec<BandDto>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EffectParamDto {
    pub name: String,
    pub value: f32,
    pub default_value: f32,
    pub min: f32,
    pub max: f32,
    pub step: f32,
    pub unit: String,
    pub index: u32,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AudioEffectDto {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub params: Vec<EffectParamDto>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(thiserror::Error, Debug)]
pub enum AppError {
    #[error("Audio system not initialized")]
    NotInitialized,
    #[error("API error: {0}")]
    ApiError(String),
    #[error("Database error: {0}")]
    DbError(String),
    #[error("Invalid token or session expired")]
    Unauthorized,
    #[error("Invalid token")]
    InvalidToken,
    #[error("Network error: please check your connection")]
    NetworkError,
    #[error("Resource not found: {0}")]
    NotFound(String),
    #[error("Rate limited: too many requests")]
    RateLimited,
    #[error("Unknown error: {0}")]
    Unknown(String),
}

impl From<Box<dyn std::error::Error + Send + Sync>> for AppError {
    fn from(err: Box<dyn std::error::Error + Send + Sync>) -> Self {
        let s = err.to_string();
        if s.contains("401") || s.contains("unauthorized") {
            AppError::Unauthorized
        } else if s.contains("404") || s.contains("not found") {
            AppError::NotFound(s)
        } else if s.contains("429") || s.contains("too many requests") {
            AppError::RateLimited
        } else if s.contains("timeout") || s.contains("connection") {
            AppError::NetworkError
        } else {
            AppError::ApiError(s)
        }
    }
}
