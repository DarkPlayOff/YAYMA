use crate::api::models::{
    AlbumDetailsDto, AppError, ArtistDetailsDto, PlaylistDetailsDto, SearchResultsDto,
    SimpleAlbumDto, SimpleArtistDto, SimplePlaylistDto, SimpleTrackDto, StationCategoryDto,
    StationItemDto, TrackDetailsDto, format_cover,
};
use crate::app::AppContext;
use crate::storage::cache::HttpCache;
use crate::util::flac::extract_native_flac;
use foldhash::HashMapExt;
use std::sync::Arc;
use std::sync::OnceLock;
use tokio::sync::Mutex;

const MAX_CONCURRENT_DOWNLOADS: usize = 3;
static BULK_DOWNLOAD_QUEUE: OnceLock<Mutex<()>> = OnceLock::new();
static TRACK_DOWNLOAD_LOCKS: OnceLock<Mutex<foldhash::HashMap<String, Arc<Mutex<()>>>>> =
    OnceLock::new();

fn track_download_locks() -> &'static Mutex<foldhash::HashMap<String, Arc<Mutex<()>>>> {
    TRACK_DOWNLOAD_LOCKS.get_or_init(|| Mutex::new(foldhash::HashMap::new()))
}

/// Stream a download response to `part_path` without buffering the whole
/// track in RAM (FLAC tracks are tens of MB).
async fn stream_response_to_file(
    mut response: reqwest::Response,
    part_path: &std::path::Path,
) -> Result<(), AppError> {
    use tokio::io::AsyncWriteExt;
    if let Some(parent) = part_path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| AppError::Unknown(e.to_string()))?;
    }
    let mut file = tokio::fs::File::create(part_path)
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?;
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?
    {
        file.write_all(&chunk)
            .await
            .map_err(|e| AppError::Unknown(e.to_string()))?;
    }
    file.flush()
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?;
    Ok(())
}

async fn get_liked_snapshot(
    ctx: &AppContext,
) -> (foldhash::HashSet<String>, foldhash::HashSet<String>) {
    ctx.audio.state.read().await.liked.snapshot()
}

macro_rules! map_results {
    ($opt:expr, $f:expr) => {
        $opt.map(|l| l.results.into_iter().map($f).collect())
            .unwrap_or_default()
    };
}

pub async fn search(ctx: &AppContext, query: String) -> Option<SearchResultsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let results = ctx.core.api.search(&query).await.ok()?;

    Some(SearchResultsDto {
        tracks: map_results!(results.tracks, |t| {
            SimpleTrackDto::from_yandex(&t, &liked, &disliked)
        }),
        albums: map_results!(results.albums, SimpleAlbumDto::from_yandex),
        artists: map_results!(results.artists, SimpleArtistDto::from_yandex),
        playlists: map_results!(results.playlists, SimplePlaylistDto::from_yandex),
    })
}

pub async fn set_download_path(ctx: &AppContext, path: String) -> Result<(), AppError> {
    ctx.core.db.lock().await.save_download_path(&path).await?;
    Ok(())
}

pub async fn get_download_path(ctx: &AppContext) -> Result<Option<String>, AppError> {
    Ok(ctx.core.db.lock().await.load_download_path().await?)
}

enum DownloadDestination {
    Cache,
    Files {
        directory: std::path::PathBuf,
        prefix: String,
    },
}

#[derive(Clone)]
enum DownloadBatchTarget {
    Cache,
    Files {
        directory: std::path::PathBuf,
        width: usize,
    },
}

impl DownloadBatchTarget {
    fn destination(&self, index: usize) -> DownloadDestination {
        match self {
            Self::Cache => DownloadDestination::Cache,
            Self::Files { directory, width } => DownloadDestination::Files {
                directory: directory.clone(),
                prefix: format!("{:0width$} - ", index + 1, width = width),
            },
        }
    }
}

async fn get_download_directory(ctx: &AppContext) -> Result<std::path::PathBuf, AppError> {
    ctx.core
        .db
        .lock()
        .await
        .load_download_path()
        .await
        .ok()
        .flatten()
        .map(std::path::PathBuf::from)
        .or_else(|| {
            directories::UserDirs::new().and_then(|u| u.download_dir().map(|p| p.to_path_buf()))
        })
        .ok_or_else(|| AppError::Unknown("Could not find download directory".into()))
}

fn sanitize_path_component(value: &str, fallback: &str) -> String {
    let sanitized: String = value
        .chars()
        .map(|c| match c {
            '?' | '/' | '\\' | '*' | '"' | '<' | '>' | '|' | ':' => '_',
            _ => c,
        })
        .collect();
    let sanitized = sanitized.trim().trim_matches('.');
    if sanitized.is_empty() {
        fallback.to_string()
    } else {
        sanitized.to_string()
    }
}

async fn download_track_to_destination(
    ctx: &AppContext,
    track_id: String,
    destination: DownloadDestination,
) -> Result<String, AppError> {
    let api = &ctx.core.api;
    let (liked, disliked) = get_liked_snapshot(ctx).await;

    let track = api
        .fetch_tracks(vec![track_id.clone()])
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| AppError::NotFound(format!("Track {}", track_id)))?;

    // Downloaded files are kept forever, so embed the highest-quality cover
    // available rather than whatever fixed preset display DTOs use.
    let orig_cover_url = format_cover(crate::api::models::get_any_cover(&track), "orig");
    let mut dto = SimpleTrackDto::from_yandex_owned(track, &liked, &disliked);
    dto.cover_url = orig_cover_url;

    let (url, codec) = api.fetch_track_url_for_download(track_id.clone()).await?;

    let ext = if codec.contains("flac") {
        "flac"
    } else if codec.contains("aac") {
        "m4a"
    } else {
        "mp3"
    };

    let to_cache = matches!(&destination, DownloadDestination::Cache);
    let dest_path = if to_cache {
        let mut dir = ctx.core.track_cache.get_cache_dir().to_path_buf();
        dir.push(format!("{}.{}", track_id, ext));
        dir
    } else {
        let artist_name = dto
            .artists
            .first()
            .map(|a| a.name.as_str())
            .unwrap_or("Unknown Artist");

        let (directory, prefix) = match destination {
            DownloadDestination::Files { directory, prefix } => (directory, prefix),
            DownloadDestination::Cache => unreachable!(),
        };
        let safe_base_name =
            sanitize_path_component(&format!("{} - {}", artist_name, dto.title), "Unknown Track");

        let mut dir = directory;
        dir.push(format!("{}{}.{}", prefix, safe_base_name, ext));
        dir
    };

    let bytes = if to_cache {
        // Deduplicate parallel downloads of the same track and never expose
        // a partially written file: stream to `.part`, then atomically rename.
        let guard = {
            let mut locks = track_download_locks().lock().await;
            locks
                .entry(track_id.clone())
                .or_insert_with(|| Arc::new(Mutex::new(())))
                .clone()
        };
        let _permit = guard.lock().await;

        // Another task may have finished while we waited for the lock.
        if dest_path.exists()
            && let Ok(meta) = tokio::fs::metadata(&dest_path).await
            && meta.len() > 0
        {
            return Ok(dest_path.to_string_lossy().into_owned());
        }

        let part_path = dest_path.with_extension(format!(
            "{}.part",
            dest_path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("bin")
        ));
        let response = crate::http::send_with_retry(|| api.http_client.get(&url)).await?;
        stream_response_to_file(response, &part_path).await?;
        tokio::fs::rename(&part_path, &dest_path)
            .await
            .map_err(|e| AppError::Unknown(e.to_string()))?;

        if let Some(mut url) = dto.cover_url {
            if url.starts_with("//") {
                url.insert_str(0, "https:");
            }
            if let Ok(http_path) = ctx.core.http_cache.get_file(&url).await {
                let _ = ctx.core.track_cache.save_cover(&url, &http_path).await;
            }
        }
        return Ok(dest_path.to_string_lossy().into_owned());
    } else {
        // File downloads: still stream to tmp to avoid RAM spikes.
        let tmp_path = dest_path.with_extension("download_tmp");
        let response = crate::http::send_with_retry(|| api.http_client.get(&url)).await?;
        stream_response_to_file(response, &tmp_path).await?;
        let bytes = tokio::fs::read(&tmp_path)
            .await
            .map_err(|e| AppError::Unknown(e.to_string()))?;
        let _ = tokio::fs::remove_file(&tmp_path).await;
        bytes
    };

    if to_cache {
        return Ok(dest_path.to_string_lossy().into_owned());
    }

    if ext == "flac" && !bytes.starts_with(b"fLaC") {
        let temp_path = dest_path.with_extension("m4a_tmp");
        tokio::fs::write(&temp_path, &bytes).await?;

        let input_path_str = temp_path.to_string_lossy().into_owned();
        let output_path_str = dest_path.to_string_lossy().into_owned();

        let extraction_result = tokio::task::spawn_blocking(move || {
            extract_native_flac(&input_path_str, &output_path_str)
        })
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?;

        let _ = tokio::fs::remove_file(&temp_path).await;

        if let Err(e) = extraction_result {
            tracing::error!("Failed to extract native FLAC: {}", e);
            tokio::fs::write(&dest_path, &bytes).await?;
        }
    } else {
        tokio::fs::write(&dest_path, &bytes).await?;
    }

    let cache = ctx.core.http_cache.clone();
    let _ = embed_metadata(&dest_path, dto, cache).await;
    Ok(dest_path.to_string_lossy().into_owned())
}

async fn download_tracks_with_target(
    ctx: &AppContext,
    track_ids: Vec<String>,
    target: DownloadBatchTarget,
) -> Vec<(usize, Result<String, AppError>)> {
    use futures::stream::{self, StreamExt};

    stream::iter(track_ids.into_iter().enumerate())
        .map(|(index, track_id)| {
            let ctx = ctx.clone();
            let destination = target.destination(index);
            async move {
                ctx.send_event(crate::api::simple::AppEvent::TrackDownloadStarted(
                    track_id.clone(),
                ));
                let result =
                    download_track_to_destination(&ctx, track_id.clone(), destination).await;
                match &result {
                    Ok(_) => ctx.send_event(crate::api::simple::AppEvent::TrackDownloadFinished(
                        track_id,
                    )),
                    Err(error) => {
                        ctx.send_event(crate::api::simple::AppEvent::TrackDownloadFailed(
                            track_id,
                            error.to_string(),
                        ))
                    }
                }
                (index, result)
            }
        })
        .buffer_unordered(MAX_CONCURRENT_DOWNLOADS)
        .collect()
        .await
}

pub async fn download_tracks(
    ctx: &AppContext,
    track_ids: Vec<String>,
    to_cache: bool,
    collection_name: Option<String>,
) -> Result<Vec<String>, AppError> {
    if track_ids.is_empty() {
        return Ok(Vec::new());
    }

    // Serialize independent bulk jobs so a second playlist download cannot
    // compete with the first one for bandwidth. Individual files remain
    // limited by MAX_CONCURRENT_DOWNLOADS inside the job.
    let _bulk_guard = BULK_DOWNLOAD_QUEUE
        .get_or_init(|| Mutex::new(()))
        .lock()
        .await;

    let target = if to_cache {
        DownloadBatchTarget::Cache
    } else {
        let mut directory = get_download_directory(ctx).await?;
        if let Some(collection_name) = collection_name {
            directory.push(sanitize_path_component(
                &collection_name,
                "Downloaded Collection",
            ));
            tokio::fs::create_dir_all(&directory).await?;
        }
        DownloadBatchTarget::Files {
            directory,
            width: track_ids.len().to_string().len(),
        }
    };

    let mut results = download_tracks_with_target(ctx, track_ids, target).await;
    results.sort_by_key(|(index, _)| *index);

    let mut paths = Vec::with_capacity(results.len());
    let mut first_error = None;
    for (_, result) in results {
        match result {
            Ok(path) => paths.push(path),
            Err(error) if first_error.is_none() => first_error = Some(error),
            Err(_) => {}
        }
    }

    first_error.map_or(Ok(paths), Err)
}

pub async fn delete_downloaded_track(ctx: &AppContext, track_id: String) -> Result<(), AppError> {
    ctx.core
        .track_cache
        .delete_track(&track_id)
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))?;
    Ok(())
}

async fn embed_metadata(
    path: &std::path::Path,
    dto: SimpleTrackDto,
    cache: Arc<HttpCache>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use lofty::config::{ParseOptions, WriteOptions};
    use lofty::file::TaggedFileExt;
    use lofty::picture::{MimeType, Picture, PictureType};
    use lofty::probe::Probe;
    use lofty::tag::{Accessor, Tag, TagExt};

    let path_buf = path.to_path_buf();
    let title = dto.title;
    let album = dto.album;
    let artists = {
        let mut s = String::new();
        for (i, artist) in dto.artists.into_iter().enumerate() {
            if i > 0 {
                s.push_str(", ");
            }
            s.push_str(&artist.name);
        }
        s
    };

    let cover_bytes = if let Some(mut url) = dto.cover_url {
        if url.starts_with("//") {
            url.insert_str(0, "https:");
        }
        if let Ok(path) = cache.get_file(&url).await {
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
        .core
        .api
        .fetch_tracks(vec![track_id.clone()])
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| AppError::NotFound(format!("Track {}", track_id)))?;
    Ok(TrackDetailsDto::from_yandex(track))
}

pub async fn get_album_details(ctx: &AppContext, album_id: u32) -> Option<AlbumDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let album = ctx.core.api.fetch_album_with_tracks(album_id).await.ok()?;
    Some(AlbumDetailsDto::from_yandex(album, &liked, &disliked))
}

pub async fn get_artist_details(
    ctx: &AppContext,
    artist_id: String,
    page: u32,
    page_size: u32,
) -> Option<ArtistDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let (artist_res, tracks_res) = tokio::join!(
        ctx.core.api.fetch_artist(artist_id.clone()),
        ctx.core
            .api
            .fetch_artist_tracks_paginated(artist_id.clone(), page, page_size)
    );

    let (mut artist, (tracks, pager)) = (artist_res.ok()?, tracks_res.ok()?);

    let mapped_tracks = tracks
        .into_iter()
        .map(|t| SimpleTrackDto::from_yandex(&t, &liked, &disliked))
        .collect();

    // Albums are only needed for the first page; subsequent pages just append tracks.
    let albums = if page == 0 {
        ctx.core
            .api
            .fetch_artist_albums(artist_id.clone(), 0, page_size)
            .await
            .map(|albums| {
                albums
                    .into_iter()
                    .map(SimpleAlbumDto::from_yandex)
                    .collect()
            })
            .unwrap_or_default()
    } else {
        Vec::new()
    };

    Some(ArtistDetailsDto {
        id: artist_id,
        name: artist.name.take().unwrap_or_default(),
        cover_url: format_cover(artist.cover.and_then(|mut c| c.uri.take()), "600x600"),
        tracks: mapped_tracks,
        total_tracks: pager.total,
        albums,
    })
}

pub async fn get_playlist_details(
    ctx: &AppContext,
    _uid: i64,
    kind: u32,
    query: Option<String>,
) -> Option<PlaylistDetailsDto> {
    let (liked, disliked) = get_liked_snapshot(ctx).await;
    let mut playlist = ctx.core.api.fetch_playlist(kind).await.ok()?;
    let tracks_enum = playlist
        .tracks
        .take()
        .unwrap_or_else(|| yandex_music::model::playlist::PlaylistTracks::Full(vec![]));
    let tracks_vec = crate::util::track::fetch_full_tracks(&ctx.core.api, tracks_enum).await;

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
    let stations = ctx.core.api.fetch_stations().await.unwrap_or_default();
    let mut grouped: foldhash::HashMap<String, Vec<StationItemDto>> = foldhash::HashMap::new();

    for rotor in stations {
        let station = rotor.station;
        let mut item_type = station.id.item_type;
        let seed = format!("{}:{}", item_type, station.id.tag);

        let cat_key = if item_type == "mix" {
            "Моя волна".to_string()
        } else {
            std::mem::take(&mut item_type)
        };

        grouped.entry(cat_key).or_default().push(StationItemDto {
            label: station.name,
            seed,
        });
    }

    let mut cats: Vec<StationCategoryDto> = grouped
        .into_iter()
        .map(|(k, mut v)| {
            let title = if k == "Моя волна" {
                k
            } else {
                let mut chars = k.chars();
                chars.next().map_or(String::new(), |f| {
                    f.to_uppercase().collect::<String>() + chars.as_str()
                })
            };
            v.sort_by(|a, b| a.label.cmp(&b.label));
            StationCategoryDto { title, items: v }
        })
        .collect();

    cats.sort_by(|a, b| match (a.title.as_str(), b.title.as_str()) {
        ("Моя волна", _) => std::cmp::Ordering::Less,
        (_, "Моя волна") => std::cmp::Ordering::Greater,
        (a_str, b_str) => a_str.cmp(b_str),
    });
    cats
}
