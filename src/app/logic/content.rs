use crate::api::models::{
    AlbumDetailsDto, AppError, ArtistDetailsDto, PlaylistDetailsDto, SearchResultsDto,
    SimpleAlbumDto, SimpleArtistDto, SimplePlaylistDto, SimpleTrackDto, StationCategoryDto,
    StationItemDto, TrackDetailsDto, format_cover,
};
use crate::app::AppContext;
use crate::storage::cache::get_http_cache;
use crate::util::flac::extract_native_flac;
use foldhash::HashMapExt;

async fn get_liked_snapshot(
    ctx: &AppContext,
) -> (foldhash::HashSet<String>, foldhash::HashSet<String>) {
    ctx.state.read().await.liked.snapshot()
}

pub async fn search(ctx: &AppContext, query: String) -> Option<SearchResultsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;

    match ctx.api.search(&query).await {
        Ok(results) => {
            let tracks = results
                .tracks
                .map(|t| {
                    t.results
                        .into_iter()
                        .map(|track| SimpleTrackDto::from_yandex(&track, &liked, &disliked))
                        .collect()
                })
                .unwrap_or_default();

            let albums = results
                .albums
                .map(|a| {
                    a.results
                        .into_iter()
                        .map(SimpleAlbumDto::from_yandex)
                        .collect()
                })
                .unwrap_or_default();

            let artists = results
                .artists
                .map(|a| {
                    a.results
                        .into_iter()
                        .map(SimpleArtistDto::from_yandex)
                        .collect()
                })
                .unwrap_or_default();

            let playlists = results
                .playlists
                .map(|p| {
                    p.results
                        .into_iter()
                        .map(SimplePlaylistDto::from_yandex)
                        .collect()
                })
                .unwrap_or_default();

            Some(SearchResultsDto {
                tracks,
                albums,
                artists,
                playlists,
            })
        }
        Err(e) => {
            tracing::error!("Search error: {:?}", e);
            None
        }
    }
}

pub async fn set_download_path(ctx: &AppContext, path: String) -> Result<(), AppError> {
    let db = ctx.db.lock();
    db.save_download_path(&path)
        .map_err(|e| AppError::DbError(e.to_string()))?;
    Ok(())
}

pub async fn get_download_path(ctx: &AppContext) -> Result<Option<String>, AppError> {
    let db = ctx.db.lock();
    db.load_download_path()
        .map_err(|e| AppError::DbError(e.to_string()))
}

pub async fn download_track(ctx: &AppContext, track_id: String) -> Result<String, AppError> {
    let api = &ctx.api;
    let (liked, disliked) = get_liked_snapshot(ctx).await;

    let track = api
        .fetch_tracks(vec![track_id.clone()])
        .await
        .map_err(|e| AppError::ApiError(e.to_string()))?
        .into_iter()
        .next()
        .ok_or_else(|| AppError::ApiError("Track not found".to_string()))?;

    let dto = SimpleTrackDto::from_yandex(&track, &liked, &disliked);
    let artist_name = dto
        .artists
        .first()
        .map(|a| a.name.clone())
        .unwrap_or_else(|| "Unknown Artist".into());
    let safe_base_name = format!("{} - {}", artist_name, dto.title)
        .chars()
        .map(|c| {
            if matches!(c, '?' | '/' | '\\' | '*' | '\"' | '<' | '>' | '|') {
                '_'
            } else {
                c
            }
        })
        .collect::<String>();

    let (url, codec) = api
        .fetch_track_url_for_download(track_id)
        .await
        .map_err(|e| AppError::ApiError(e.to_string()))?;

    let ext = if codec.contains("flac") {
        "flac"
    } else if codec.contains("aac") {
        "m4a"
    } else {
        "mp3"
    };
    let dest_path = {
        let db = ctx.db.lock();
        let mut dir = db
            .load_download_path()
            .ok()
            .flatten()
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| {
                directories::UserDirs::new()
                    .and_then(|u| u.download_dir().map(|p| p.to_path_buf()))
                    .unwrap_or_default()
            });
        if dir.as_os_str().is_empty() {
            return Err(AppError::Unknown(
                "Could not find download directory".to_string(),
            ));
        }
        dir.push(format!("{}.{}", safe_base_name, ext));
        dir
    };

    let response = reqwest::get(url)
        .await
        .map_err(|_| AppError::NetworkError)?;
    let bytes = response.bytes().await.map_err(|_| AppError::NetworkError)?;

    if ext == "flac" && !bytes.starts_with(b"fLaC") {
        let temp_path = dest_path.with_extension("m4a_tmp");
        tokio::fs::write(&temp_path, &bytes)
            .await
            .map_err(|e| AppError::DbError(e.to_string()))?;

        let input_path_str = temp_path.to_string_lossy().to_string();
        let output_path_str = dest_path.to_string_lossy().to_string();

        let extraction_result = tokio::task::spawn_blocking(move || {
            extract_native_flac(&input_path_str, &output_path_str)
        })
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?;

        let _ = tokio::fs::remove_file(&temp_path).await;

        if let Err(e) = extraction_result {
            tracing::error!("Failed to extract native FLAC: {}", e);
            tokio::fs::write(&dest_path, &bytes)
                .await
                .map_err(|e| AppError::DbError(e.to_string()))?;
        }
    } else {
        tokio::fs::write(&dest_path, &bytes)
            .await
            .map_err(|e| AppError::DbError(e.to_string()))?;
    }

    let _ = embed_metadata(&dest_path, &dto).await;
    Ok(dest_path.to_string_lossy().to_string())
}

async fn embed_metadata(
    path: &std::path::Path,
    dto: &SimpleTrackDto,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use lofty::config::{ParseOptions, WriteOptions};
    use lofty::file::TaggedFileExt;
    use lofty::picture::{MimeType, Picture, PictureType};
    use lofty::probe::Probe;
    use lofty::tag::{Accessor, Tag, TagExt};

    let path_buf = path.to_path_buf();
    let title = dto.title.clone();
    let artists = dto
        .artists
        .iter()
        .map(|a| a.name.clone())
        .collect::<Vec<_>>()
        .join(", ");
    let album = dto.album.clone();

    let cover_bytes = if let Some(ref url) = dto.cover_url {
        let https_url = if url.starts_with("//") {
            format!("https:{}", url)
        } else {
            url.clone()
        };
        let cache = get_http_cache().await;
        if let Ok(path) = cache.get_file(&https_url).await {
            tokio::fs::read(path).await.ok()
        } else {
            None
        }
    } else {
        None
    };

    tokio::task::spawn_blocking(move || {
        let mut tagged_file = Probe::open(&path_buf)?
            .options(ParseOptions::new().read_properties(false))
            .read()?;

        tagged_file.clear();
        let primary_tag_type = tagged_file.primary_tag_type();
        tagged_file.insert_tag(Tag::new(primary_tag_type));
        let tag = tagged_file.primary_tag_mut().unwrap();

        tag.set_title(title);
        tag.set_artist(artists);
        if let Some(album) = album {
            tag.set_album(album);
        }

        if let Some(bytes) = cover_bytes {
            tag.push_picture(
                Picture::unchecked(bytes)
                    .mime_type(MimeType::Jpeg)
                    .pic_type(PictureType::CoverFront)
                    .build(),
            );
        }

        let _ = tag.save_to_path(&path_buf, WriteOptions::default());
        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    })
    .await??;

    Ok(())
}

pub async fn get_track_details(
    ctx: &AppContext,
    track_id: String,
) -> Result<TrackDetailsDto, AppError> {
    let track = ctx
        .api
        .fetch_tracks(vec![track_id])
        .await
        .map_err(|e| AppError::ApiError(e.to_string()))?
        .into_iter()
        .next()
        .ok_or_else(|| AppError::ApiError("Track not found".to_string()))?;
    Ok(TrackDetailsDto::from_yandex(track))
}

pub async fn get_album_details(ctx: &AppContext, album_id: u32) -> Option<AlbumDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    ctx.api
        .fetch_album_with_tracks(album_id)
        .await
        .ok()
        .map(|album| AlbumDetailsDto::from_yandex(album, &liked, &disliked))
}

pub async fn get_artist_details(
    ctx: &AppContext,
    artist_id: String,
    page: u32,
    page_size: u32,
) -> Option<ArtistDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let (artist_res, tracks_res) = tokio::join!(
        ctx.api.fetch_artist(artist_id.clone()),
        ctx.api
            .fetch_artist_tracks_paginated(artist_id.clone(), page, page_size)
    );

    match (artist_res, tracks_res) {
        (Ok(mut artist), Ok((tracks, pager))) => {
            let mapped_tracks = tracks
                .into_iter()
                .map(|t| SimpleTrackDto::from_yandex(&t, &liked, &disliked))
                .collect();
            Some(ArtistDetailsDto {
                id: artist_id,
                name: artist.name.take().unwrap_or_default(),
                cover_url: format_cover(artist.cover.and_then(|mut c| c.uri.take()), "400x400"),
                tracks: mapped_tracks,
                total_tracks: pager.total,
            })
        }
        _ => None,
    }
}

pub async fn get_playlist_details(
    ctx: &AppContext,
    _uid: i64,
    kind: u32,
    query: Option<String>,
) -> Option<PlaylistDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let mut playlist = ctx.api.fetch_playlist(kind).await.ok()?;
    let tracks_enum = playlist
        .tracks
        .take()
        .unwrap_or_else(|| yandex_music::model::playlist::PlaylistTracks::Full(vec![]));
    let tracks_vec = crate::util::track::fetch_full_tracks(&ctx.api, tracks_enum).await;

    let query_lower = query.map(|q| q.to_lowercase());
    let mapped_tracks: Vec<SimpleTrackDto> = tracks_vec
        .into_iter()
        .filter(|t| {
            let q = query_lower.as_ref();
            q.is_none_or(|query| {
                t.title
                    .as_ref()
                    .is_some_and(|title| title.to_lowercase().contains(query))
                    || t.artists.iter().any(|a| {
                        a.name
                            .as_ref()
                            .is_some_and(|n| n.to_lowercase().contains(query))
                    })
            })
        })
        .map(|t| SimpleTrackDto::from_yandex(&t, &liked, &disliked))
        .collect();

    let mut dto = PlaylistDetailsDto::from_yandex(playlist);
    dto.tracks = mapped_tracks;
    Some(dto)
}

pub async fn fetch_wave_stations(ctx: &AppContext) -> Vec<StationCategoryDto> {
    let Ok(stations) = ctx.api.fetch_stations().await else {
        return vec![];
    };
    let mut grouped: foldhash::HashMap<String, Vec<StationItemDto>> = foldhash::HashMap::new();

    for rotor in stations {
        let station = rotor.station;
        let item_type = station.id.item_type;
        let cat_key = if item_type == "mix" {
            "Моя волна".to_string()
        } else {
            item_type.clone()
        };
        grouped.entry(cat_key).or_default().push(StationItemDto {
            label: station.name,
            seed: format!("{}:{}", item_type, station.id.tag),
        });
    }

    let mut cats: Vec<StationCategoryDto> = grouped
        .into_iter()
        .map(|(k, mut v): (String, Vec<StationItemDto>)| {
            let title = if k == "Моя волна" {
                k
            } else {
                let mut chars = k.chars();
                chars.next().map_or(String::new(), |f: char| {
                    f.to_uppercase().collect::<String>() + chars.as_str()
                })
            };
            v.sort_by_key(|i: &StationItemDto| i.label.clone());
            StationCategoryDto { title, items: v }
        })
        .collect();

    cats.sort_by(|a: &StationCategoryDto, b: &StationCategoryDto| {
        match (a.title.as_str(), b.title.as_str()) {
            ("Моя волна", _) => std::cmp::Ordering::Less,
            (_, "Моя волна") => std::cmp::Ordering::Greater,
            (a_str, b_str) => a_str.cmp(b_str),
        }
    });
    cats
}

pub async fn get_lyrics(ctx: &AppContext, track_id: String) -> Option<String> {
    ctx.api
        .fetch_lyrics(
            track_id,
            yandex_music::model::info::lyrics::LyricsFormat::LRC,
        )
        .await
        .ok()
        .flatten()
}
