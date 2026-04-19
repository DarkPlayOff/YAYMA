use crate::api::models::{SimplePlaylistDto, SimpleTrackDto};
use crate::app::AppContext;
use crate::frb_generated::StreamSink;
use foldhash::HashMapExt;

pub async fn toggle_like(ctx: &AppContext, track_id: String) {
    let is_liked = {
        let state = ctx.state.read().await;
        state.liked.is_liked(&track_id)
    };

    // Instant local update (Optimistic UI)
    {
        let mut state = ctx.state.write().await;
        state.liked.set_like_status(&track_id, !is_liked);

        // Update DB immediately for search and offline access
        let db = ctx.db.lock();
        if is_liked {
            let _ = db.remove_liked_track(&track_id);
        } else {
            let _ = db.add_liked_track(&track_id);
        }

        ctx.signals.library_changed.send_replace(());
        ctx.signals.changed.send_replace(());
    }

    // Perform API request in background
    let api = ctx.api.clone();
    let audio_tx = ctx.audio_tx.clone();
    tokio::spawn(async move {
        if is_liked {
            let _ = api.remove_like_track(track_id.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveUnlike(track_id))
                .await;
        } else {
            let _ = api.add_like_track(track_id.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveLike(track_id))
                .await;
        }
    });

    // Vibe effect (if liking)
    if !is_liked && let Ok(mut vibe) = ctx.signals.monitor.vibe.try_lock() {
        vibe.trigger_like();
    }
}

pub async fn toggle_dislike(ctx: &AppContext, track_id: String) {
    let is_disliked = {
        let state = ctx.state.read().await;
        state.liked.is_disliked(&track_id)
    };

    // Instant local update
    {
        let mut state = ctx.state.write().await;
        state.liked.set_dislike_status(&track_id, !is_disliked);
        ctx.signals.library_changed.send_replace(());
        ctx.signals.changed.send_replace(());
    }

    // Perform API request in background
    let api = ctx.api.clone();
    let track_id_clone = track_id.clone();
    let audio_tx = ctx.audio_tx.clone();
    tokio::spawn(async move {
        if is_disliked {
            let _ = api.remove_dislike_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveUndislike(
                    track_id_clone,
                ))
                .await;
        } else {
            let _ = api.add_dislike_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveDislike(
                    track_id_clone,
                ))
                .await;
        }
    });
}

pub async fn upload_user_track(
    ctx: &AppContext,
    file_path: String,
    playlist_kind: Option<u32>,
) -> bool {
    let api = &ctx.api;

    let file_name = std::path::Path::new(&file_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("track.mp3");

    // Use 1000 (Likes) as default playlist for upload
    let kind = playlist_kind.unwrap_or(1000);

    // 1. Get upload info (target URL)
    let upload_url = match api.fetch_ugc_upload_info(kind, file_name).await {
        Ok(url) => url,
        Err(e) => {
            tracing::error!("Failed to get upload info: {:?}", e);
            return false;
        }
    };

    // 2. Upload file
    let track_id = match api.upload_ugc_track(&upload_url, &file_path).await {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to upload track: {:?}", e);
            return false;
        }
    };

    // 3. If uploading to a specific playlist (not Likes), add it explicitly
    // Since upload via loader might not bind the track automatically.
    if let Some(k) = playlist_kind {
        let _ = api.add_track_to_playlist(k, track_id, String::new()).await;
    }

    true
}

pub async fn get_playlists(ctx: &AppContext) -> Vec<SimplePlaylistDto> {
    match ctx.api.fetch_all_playlists().await {
        Ok(playlists) => playlists
            .into_iter()
            .map(SimplePlaylistDto::from_yandex)
            .collect(),
        Err(_) => vec![],
    }
}

pub async fn add_track_to_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .add_track_to_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok()
}

pub async fn remove_track_from_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .remove_track_from_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok()
}

pub async fn create_playlist(ctx: &AppContext, title: String, is_public: bool) -> bool {
    ctx.api.create_playlist(title, is_public).await.is_ok()
}

pub async fn delete_playlist(ctx: &AppContext, kind: u32) -> bool {
    ctx.api.delete_playlist(kind).await.is_ok()
}

pub async fn rename_playlist(ctx: &AppContext, kind: u32, new_title: String) -> bool {
    ctx.api.rename_playlist(kind, new_title).await.is_ok()
}

pub async fn set_playlist_visibility(ctx: &AppContext, kind: u32, is_public: bool) -> bool {
    ctx.api
        .change_playlist_visibility(kind, is_public)
        .await
        .is_ok()
}

pub async fn move_track_in_playlist(
    ctx: &AppContext,
    kind: u32,
    from_index: u32,
    to_index: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .move_track_in_playlist(
            kind,
            from_index as usize,
            to_index as usize,
            track_id,
            album_id.unwrap_or_default(),
        )
        .await
        .is_ok()
}

async fn fetch_and_save_missing_metadata(
    ctx: &AppContext,
    missing_ids: Vec<String>,
    metadata_map: &mut foldhash::HashMap<String, crate::storage::db::TrackMetadata>,
) {
    if missing_ids.is_empty() {
        return;
    }

    for chunk in missing_ids.chunks(50) {
        if let Ok(tracks) = ctx.api.fetch_tracks(chunk.to_vec()).await {
            for t in tracks {
                let artists: Vec<crate::api::models::TrackArtistDto> = t
                    .artists
                    .into_iter()
                    .map(|a| crate::api::models::TrackArtistDto::from_yandex(&a))
                    .collect();
                let album = t.albums.first().and_then(|a| a.title.clone());
                let album_id = t.albums.first().and_then(|a| a.id).map(|id| id.to_string());
                let cover_url = t
                    .og_image
                    .as_ref()
                    .map(|img| format!("https://{}", img.replace("%%", "200x200")));

                let duration_ms = t.duration.map(|d| d.as_millis() as u64).unwrap_or(0);

                let metadata_to_save = crate::storage::db::TrackMetadata {
                    id: t.id.clone(),
                    title: t.title.clone().unwrap_or_default(),
                    version: t.version.clone(),
                    artists,
                    album,
                    album_id,
                    cover_url,
                    duration_ms,
                };

                let _ = ctx.db.lock().upsert_track_metadata(metadata_to_save.clone());
                metadata_map.insert(t.id, metadata_to_save);
            }
        }
    }
}

fn metadata_to_dto(
    m: crate::storage::db::TrackMetadata,
    is_liked: bool,
    is_disliked: bool,
) -> SimpleTrackDto {
    SimpleTrackDto {
        id: m.id,
        title: m.title,
        version: m.version,
        artists: m.artists,
        album: m.album,
        album_id: m.album_id,
        cover_url: m.cover_url,
        duration_ms: m.duration_ms as u32,
        is_liked,
        is_disliked,
    }
}

pub async fn liked_tracks_stream(
    ctx: &AppContext,
    sink: StreamSink<Vec<SimpleTrackDto>>,
    query: Option<String>,
) {
    let mut changed_rx = ctx.signals.library_changed_rx.clone();

    loop {
        // Send an empty list as a reset signal for the frontend
        // to avoid duplicates during updates.
        if sink.add(vec![]).is_err() {
            return;
        }

        let (liked_ids, disliked_ids_set) = ctx.state.read().await.liked.ordered_snapshot();

        // 1. Search processing (using DB)
        if let Some(ref q) = query
            && !q.trim().is_empty()
        {
            if let Ok(found_ids) = ctx.db.lock().search_liked_tracks(q)
                && !found_ids.is_empty()
            {
                // Use metadata from DB for search
                if let Ok(metadata) = ctx.db.lock().get_track_metadata(&found_ids) {
                    let mut dtos = Vec::with_capacity(50);
                    for m in metadata {
                        dtos.push(metadata_to_dto(m, true, false));

                        if dtos.len() >= 50 {
                            if sink.add(std::mem::take(&mut dtos)).is_err() {
                                return;
                            }
                        }
                    }
                    if !dtos.is_empty() {
                        let _ = sink.add(dtos);
                    }
                }
            } else {
                let _ = sink.add(vec![]);
            }
        } else {
            // 2. Main list (Local-First)
            if liked_ids.is_empty() {
                // If local is empty, might not have synced yet
                let _ = ctx
                    .audio_tx
                    .send(crate::audio::commands::AudioMessage::SyncLiked)
                    .await;
            }

            // Try to fetch metadata from DB for all liked IDs
            let mut metadata_map = foldhash::HashMap::new();
            if let Ok(metadata) = ctx.db.lock().get_track_metadata(&liked_ids) {
                for m in metadata {
                    metadata_map.insert(m.id.clone(), m);
                }
            }

            // Check which tracks are missing metadata or have incomplete artist info (missing IDs)
            let missing_ids: Vec<String> = liked_ids
                .iter()
                .filter(|id| {
                    match metadata_map.get(*id) {
                        None => true,
                        Some(m) => {
                            // If artists list is empty or any artist has an empty ID, 
                            // we consider it incomplete/old metadata and trigger a refresh.
                            m.artists.is_empty() || m.artists.iter().any(|a| a.id.is_empty())
                        }
                    }
                })
                .cloned()
                .collect();

            fetch_and_save_missing_metadata(ctx, missing_ids, &mut metadata_map).await;

            // Build final DTO list in correct order
            let mut dtos = Vec::with_capacity(50);
            for id in liked_ids {
                if let Some(m) = metadata_map.remove(&id) {
                    dtos.push(metadata_to_dto(m, true, disliked_ids_set.contains(&id)));

                    if dtos.len() >= 50 {
                        if sink.add(std::mem::take(&mut dtos)).is_err() {
                            return;
                        }
                    }
                }
            }
            if !dtos.is_empty() {
                let _ = sink.add(dtos);
            }
        }

        // Wait for signal changes
        if changed_rx.changed().await.is_err() {
            break;
        }
    }
}
