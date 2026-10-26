use crate::api::models::{
    COVER_SIZE_MEDIUM, PlaylistDetailsDto, SimpleAlbumDto, SimpleArtistDto, SimplePlaylistDto,
    SimpleTrackDto, format_cover, get_any_cover,
};
use crate::app::AppContext;
use crate::frb_generated::StreamSink;
use crate::util::track::{CleanId, like_entity_id};
use foldhash::HashMapExt;
use futures::StreamExt;

/// `app_settings` key holding the disliked track ids (JSON array).
pub const DISLIKED_TRACKS_KEY: &str = "disliked_tracks";

/// Resolves the full `"id:album"` entity id for like/unlike HTTP requests.
///
/// Cache/DB/Wave keep using the base id; only the likes HTTP API needs the
/// composite form (original `toggleTrackLike`: `albumId ? "id:albumId" : id`).
/// Album is taken from the `track_id` suffix when present, otherwise looked up
/// in the track-metadata DB (signatures stay unchanged, no Flutter/FRB churn).
async fn resolve_like_entity_id(ctx: &AppContext, track_id: &str) -> String {
    if track_id.contains(':') {
        return track_id.to_string();
    }
    let base_id = track_id.to_base_id().to_string();
    let album_id = ctx
        .core
        .db
        .lock()
        .await
        .get_track_metadata(&[base_id.clone()])
        .await
        .ok()
        .and_then(|mut v| v.pop())
        .and_then(|m| m.album_id);
    like_entity_id(&base_id, album_id.as_deref())
}

pub async fn track_is_liked(ctx: &AppContext, track_id: String) -> bool {
    ctx.audio.state.read().await.liked.is_liked(&track_id)
}

pub async fn track_is_disliked(ctx: &AppContext, track_id: String) -> bool {
    ctx.audio.state.read().await.liked.is_disliked(&track_id)
}

/// Tracks marked «не нравится», newest dislike first. Fetched from the server
/// so a pull-to-refresh actually refreshes; the result also replaces the cached
/// dislike set and is persisted in the same order, so the offline list and the
/// track menu agree with the server.
pub async fn get_disliked_tracks(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    let ids = match ctx.core.api.fetch_disliked_ids().await {
        Ok(ids) => {
            ctx.audio
                .state
                .write()
                .await
                .liked
                .set_disliked_ids(ids.clone());
            let mut db = ctx.core.db.lock().await;
            if let Err(e) = db.save_setting(DISLIKED_TRACKS_KEY, &ids).await {
                tracing::warn!("Failed to persist disliked tracks: {:?}", e);
            }
            drop(db);
            ids
        }
        Err(e) => {
            tracing::warn!("Failed to fetch disliked tracks: {:?}", e);
            // Offline: the persisted list keeps the dislike order; the
            // in-memory set has none to offer.
            let persisted: Option<Vec<String>> = {
                let mut db = ctx.core.db.lock().await;
                db.load_setting(DISLIKED_TRACKS_KEY).await.ok().flatten()
            };
            match persisted {
                Some(ids) if !ids.is_empty() => ids,
                _ => ctx
                    .audio
                    .state
                    .read()
                    .await
                    .liked
                    .snapshot()
                    .1
                    .into_iter()
                    .collect(),
            }
        }
    };
    // `build_track_dtos` keeps the input order, so the server's
    // newest-dislike-first order survives without a second sort.
    build_track_dtos(ctx, ids).await
}

/// Returns `true` when the server confirmed the like change. On failure the
/// optimistic state is rolled back and `false` is returned so the caller can
/// revert its own optimistic UI.
pub async fn toggle_like(ctx: &AppContext, track_id: String) -> bool {
    let is_liked = {
        let state = ctx.audio.state.read().await;
        state.liked.is_liked(&track_id)
    };

    // Instant local update (Optimistic UI)
    {
        {
            let mut state = ctx.audio.state.write().await;
            state.liked.set_like_status(&track_id, !is_liked);
            ctx.audio.signals.library_changed.send_replace(());
            ctx.audio.signals.changed.send_replace(());
        }

        // Update DB immediately for search and offline access.
        // DB is keyed by base id (exact `WHERE track_id = ?1`); normalize so
        // composite "id:album" callers don't leave stale rows.
        let base_id = track_id.to_base_id().to_string();
        let mut db = ctx.core.db.lock().await;
        if is_liked {
            if let Err(e) = db.remove_liked_track(&base_id).await {
                tracing::error!("Failed to remove liked track from DB: {:?}", e);
            }
        } else {
            if let Err(e) = db.add_liked_track(&base_id).await {
                tracing::error!("Failed to add liked track to DB: {:?}", e);
            }
        }
    }

    // Perform the API request before returning so the caller learns whether
    // the server accepted the change. The optimistic state above keeps the UI
    // instant; this await only delays the result, not the visual feedback.
    // HTTP needs the full "id:album" entity id; cache/DB/Wave keep base id.
    let api = ctx.core.api.clone();
    let audio_tx = ctx.audio.tx.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let db = ctx.core.db.clone();
    let expected = !is_liked;
    let entity_id = resolve_like_entity_id(ctx, &track_id).await;
    let api_result = if is_liked {
        api.remove_like_track(entity_id.clone()).await
    } else {
        api.add_like_track(entity_id.clone()).await
    };
    let confirmed = match api_result {
        Ok(_) => {
            let msg = if is_liked {
                crate::audio::commands::AudioMessage::WaveUnlike(track_id)
            } else {
                crate::audio::commands::AudioMessage::WaveLike(track_id)
            };
            let _ = audio_tx.send(msg).await;
            // Reconcile the optimistic cache with server truth (concurrent
            // edits from another client, partial failures). Cheap when in
            // sync: the stream dedups identical id sets and skips rebuild.
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::SyncLiked)
                .await;
            true
        }
        Err(e) => {
            tracing::warn!("toggle_like API failed, rolling back: {:?}", e);
            // Don't overwrite a newer user action: roll back only if the
            // current status still equals the optimistic value.
            let should_rollback = {
                let s = state.read().await;
                s.liked.is_liked(&track_id) == expected
            };
            if should_rollback {
                {
                    let mut s = state.write().await;
                    s.liked.set_like_status(&track_id, is_liked);
                }
                {
                    let mut db = db.lock().await;
                    let base_id = track_id.to_base_id().to_string();
                    if is_liked {
                        // We optimistically removed -> restore
                        if let Err(e) = db.add_liked_track(&base_id).await {
                            tracing::warn!("toggle_like rollback DB add failed: {:?}", e);
                        }
                    } else if let Err(e) = db.remove_liked_track(&base_id).await {
                        tracing::warn!("toggle_like rollback DB remove failed: {:?}", e);
                    }
                }
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
            false
        }
    };

    // Vibe effect (if liking)
    if !is_liked && let Ok(mut vibe) = ctx.audio.signals.monitor.vibe.try_lock() {
        vibe.trigger_like();
    }

    confirmed
}

pub async fn toggle_dislike(ctx: &AppContext, track_id: String) {
    let is_disliked = {
        let state = ctx.audio.state.read().await;
        state.liked.is_disliked(&track_id)
    };

    // Instant local update
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_dislike_status(&track_id, !is_disliked);
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }

    // Perform API request in background (with optimistic-UI rollback on error)
    // HTTP needs the full "id:album" entity id; cache/Wave keep base id.
    let api = ctx.core.api.clone();
    let audio_tx = ctx.audio.tx.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let entity_id = resolve_like_entity_id(ctx, &track_id).await;
    tokio::spawn(async move {
        let api_result = if is_disliked {
            api.remove_dislike_track(entity_id.clone()).await
        } else {
            api.add_dislike_track(entity_id.clone()).await
        };
        match api_result {
            Ok(_) => {
                let msg = if is_disliked {
                    crate::audio::commands::AudioMessage::WaveUndislike(track_id)
                } else {
                    crate::audio::commands::AudioMessage::WaveDislike(track_id)
                };
                let _ = audio_tx.send(msg).await;
            }
            Err(e) => {
                tracing::warn!("toggle_dislike API failed, rolling back: {:?}", e);
                let should_rollback = {
                    let s = state.read().await;
                    s.liked.is_disliked(&track_id) == !is_disliked
                };
                if should_rollback {
                    {
                        let mut s = state.write().await;
                        s.liked.set_dislike_status(&track_id, is_disliked);
                    }
                    signals.library_changed.send_replace(());
                    signals.changed.send_replace(());
                }
            }
        }
    });
}

pub async fn upload_user_track(
    ctx: &AppContext,
    file_path: String,
    playlist_kind: Option<u32>,
) -> bool {
    let api = &ctx.core.api;

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

/// Max playlist title length, mirrors the original desktop client model
/// (933-*.js `changeTitle` rejects `t.length < 1 || t.length > c`, `c` ~= 200).
const PLAYLIST_TITLE_MAX_LEN: usize = 200;

/// Shared title validation for create/rename: trimmed title must be 1..=200 chars.
/// Returns the trimmed title, or `None` when invalid (caller returns `false`,
/// original surfaced `ERROR`).
fn valid_playlist_title(title: &str) -> Option<String> {
    let t = title.trim();
    if t.is_empty() || t.chars().count() > PLAYLIST_TITLE_MAX_LEN {
        return None;
    }
    Some(t.to_string())
}

pub async fn get_playlists(ctx: &AppContext) -> Vec<SimplePlaylistDto> {
    match ctx.core.api.fetch_all_playlists().await {
        Ok(playlists) => playlists
            .into_iter()
            .map(SimplePlaylistDto::from_yandex)
            .collect(),
        Err(e) => {
            tracing::error!("Failed to fetch playlists: {:?}", e);
            vec![]
        }
    }
}

pub async fn get_liked_albums(ctx: &AppContext) -> Vec<SimpleAlbumDto> {
    match ctx.core.api.fetch_liked_albums().await {
        Ok(albums) => albums
            .into_iter()
            .map(SimpleAlbumDto::from_yandex)
            .collect(),
        Err(e) => {
            tracing::error!("Failed to fetch liked albums: {:?}", e);
            vec![]
        }
    }
}

pub async fn get_liked_artists(ctx: &AppContext) -> Vec<SimpleArtistDto> {
    match ctx.core.api.fetch_liked_artists().await {
        Ok(artists) => artists
            .into_iter()
            .map(SimpleArtistDto::from_yandex)
            .collect(),
        Err(e) => {
            tracing::error!("Failed to fetch liked artists: {:?}", e);
            vec![]
        }
    }
}

pub async fn add_liked_album(ctx: &AppContext, album_id: u32) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_album_like_status(album_id, true);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    tokio::spawn(async move {
        let _ = api.add_like_album(album_id).await;
    });

    true
}

pub async fn remove_liked_album(ctx: &AppContext, album_id: u32) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_album_like_status(album_id, false);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    tokio::spawn(async move {
        let _ = api.remove_like_album(album_id).await;
    });

    true
}

pub async fn add_liked_artist(ctx: &AppContext, artist_id: String) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_artist_like_status(&artist_id, true);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let id = artist_id.clone();
    tokio::spawn(async move {
        if let Err(e) = api.add_like_artist(id.clone()).await {
            tracing::warn!("add_liked_artist API failed, rolling back: {:?}", e);
            if state.read().await.liked.is_artist_liked(&id) {
                state.write().await.liked.set_artist_like_status(&id, false);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn remove_liked_artist(ctx: &AppContext, artist_id: String) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_artist_like_status(&artist_id, false);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let id = artist_id.clone();
    tokio::spawn(async move {
        if let Err(e) = api.remove_like_artist(id.clone()).await {
            tracing::warn!("remove_liked_artist API failed, rolling back: {:?}", e);
            if !state.read().await.liked.is_artist_liked(&id) {
                state.write().await.liked.set_artist_like_status(&id, true);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn add_disliked_artist(ctx: &AppContext, artist_id: String) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_artist_dislike_status(&artist_id, true);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let id = artist_id.clone();
    tokio::spawn(async move {
        if let Err(e) = api.add_dislike_artist(id.clone()).await {
            tracing::warn!("add_disliked_artist API failed, rolling back: {:?}", e);
            if state.read().await.liked.is_artist_disliked(&id) {
                state
                    .write()
                    .await
                    .liked
                    .set_artist_dislike_status(&id, false);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn remove_disliked_artist(ctx: &AppContext, artist_id: String) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_artist_dislike_status(&artist_id, false);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    let id = artist_id.clone();
    tokio::spawn(async move {
        if let Err(e) = api.remove_dislike_artist(id.clone()).await {
            tracing::warn!("remove_disliked_artist API failed, rolling back: {:?}", e);
            if !state.read().await.liked.is_artist_disliked(&id) {
                state.write().await.liked.set_artist_dislike_status(&id, true);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn add_liked_playlist(ctx: &AppContext, owner_uid: u64, kind: u32) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_playlist_like_status(owner_uid, kind, true);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    tokio::spawn(async move {
        if let Err(e) = api.add_like_playlist(owner_uid, kind).await {
            tracing::warn!("add_liked_playlist API failed, rolling back: {:?}", e);
            if state.read().await.liked.is_playlist_liked(owner_uid, kind) {
                state
                    .write()
                    .await
                    .liked
                    .set_playlist_like_status(owner_uid, kind, false);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn remove_liked_playlist(ctx: &AppContext, owner_uid: u64, kind: u32) -> bool {
    {
        let mut state = ctx.audio.state.write().await;
        state.liked.set_playlist_like_status(owner_uid, kind, false);
    }
    ctx.audio.signals.library_changed.send_replace(());
    ctx.audio.signals.changed.send_replace(());

    let api = ctx.core.api.clone();
    let state = ctx.audio.state.clone();
    let signals = ctx.audio.signals.clone();
    tokio::spawn(async move {
        if let Err(e) = api.remove_like_playlist(owner_uid, kind).await {
            tracing::warn!("remove_liked_playlist API failed, rolling back: {:?}", e);
            if !state.read().await.liked.is_playlist_liked(owner_uid, kind) {
                state
                    .write()
                    .await
                    .liked
                    .set_playlist_like_status(owner_uid, kind, true);
                signals.library_changed.send_replace(());
                signals.changed.send_replace(());
            }
        }
    });

    true
}

pub async fn add_track_to_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    let ok = ctx
        .core
        .api
        .add_track_to_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

pub async fn remove_track_from_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    let ok = ctx
        .core
        .api
        .remove_track_from_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

pub async fn create_playlist(ctx: &AppContext, title: String, is_public: bool) -> bool {
    let Some(title) = valid_playlist_title(&title) else {
        return false;
    };
    let ok = ctx.core.api.create_playlist(title, is_public).await.is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

/// NOTE: the original `deletePlaylist` refused when `!canUserChange` and
/// unpinned the playlist. We track no ownership/pin flags here, and system
/// kinds (e.g. 3 = liked tracks, 1000 = likes/upload target) are deletable
/// only server-side — so nothing is blocked client-side; the API error (if any)
/// simply yields `false` with signals untouched.
pub async fn delete_playlist(ctx: &AppContext, kind: u32) -> bool {
    let ok = ctx.core.api.delete_playlist(kind).await.is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

pub async fn rename_playlist(ctx: &AppContext, kind: u32, new_title: String) -> bool {
    let Some(title) = valid_playlist_title(&new_title) else {
        return false;
    };
    // Original `e.title === t` fast path: no request when the title is unchanged.
    // We hold no local playlist titles, so compare against a lightweight fetch;
    // on fetch failure fall through to the rename request rather than lie.
    match ctx.core.api.fetch_playlist_bare(kind).await {
        Ok(pl) if pl.title == title => return true,
        Err(e) => tracing::debug!("rename_playlist prefetch failed, proceeding: {:?}", e),
        _ => {}
    }
    let ok = ctx.core.api.rename_playlist(kind, title).await.is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

pub async fn set_playlist_visibility(ctx: &AppContext, kind: u32, is_public: bool) -> bool {
    let ok = ctx
        .core
        .api
        .change_playlist_visibility(kind, is_public)
        .await
        .is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

pub async fn move_track_in_playlist(
    ctx: &AppContext,
    kind: u32,
    from_index: u32,
    to_index: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    let ok = ctx
        .core
        .api
        .move_track_in_playlist(
            kind,
            from_index as usize,
            to_index as usize,
            track_id,
            album_id.unwrap_or_default(),
        )
        .await
        .is_ok();
    if ok {
        ctx.audio.signals.library_changed.send_replace(());
        ctx.audio.signals.changed.send_replace(());
    }
    ok
}

/// Single `Track` -> DB-metadata conversion shared by the fetch-top-up path
/// and the server-payload seeding path, so both store identical rows.
fn yandex_track_to_metadata(
    mut t: yandex_music::model::track::Track,
) -> crate::storage::db::TrackMetadata {
    let artists: Vec<crate::api::models::TrackArtistDto> = t
        .artists
        .iter()
        .map(crate::api::models::TrackArtistDto::from_yandex)
        .collect();
    let album = t.albums.first_mut().and_then(|a| a.title.take());
    let album_id = t
        .albums
        .first_mut()
        .and_then(|a| a.id.take())
        .map(|id| id.to_string());
    let cover_url = format_cover(get_any_cover(&t), COVER_SIZE_MEDIUM);
    let duration_ms = t.duration.map(|d| d.as_millis() as u64).unwrap_or(0);

    crate::storage::db::TrackMetadata {
        id: t.id,
        title: t.title.take().unwrap_or_default(),
        version: t.version.take(),
        artists,
        album,
        album_id,
        cover_url,
        duration_ms,
    }
}

async fn fetch_and_save_missing_metadata(
    ctx: &AppContext,
    missing_ids: Vec<String>,
    metadata_map: &mut foldhash::HashMap<String, crate::storage::db::TrackMetadata>,
) {
    if missing_ids.is_empty() {
        return;
    }

    // Huge libraries can miss thousands of metadata rows (cold DB after
    // reinstall): fetch 50-chunks concurrently instead of one round-trip
    // at a time. DB writes stay sequential under a single lock hold.
    let api = ctx.core.api.clone();
    let chunks: Vec<Vec<String>> = missing_ids.chunks(50).map(|c| c.to_vec()).collect();
    let fetched: Vec<Vec<yandex_music::model::track::Track>> =
        futures::stream::iter(chunks.into_iter().map(|chunk| {
            let api = api.clone();
            async move { api.fetch_tracks(chunk).await.ok().unwrap_or_default() }
        }))
        .buffer_unordered(4)
        .collect()
        .await;

    let mut db = ctx.core.db.lock().await;
    for tracks in fetched {
        for t in tracks {
            let metadata_to_save = yandex_track_to_metadata(t);
            if let Err(e) = db.upsert_track_metadata(metadata_to_save.clone()).await {
                tracing::error!("Failed to upsert track metadata in DB: {:?}", e);
            }
            metadata_map.insert(metadata_to_save.id.clone(), metadata_to_save);
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

/// Shared lowercase-contains matcher (title/artists/album) used by both the
/// liked stream and playlist details, so search/filter behaves identically
/// in both paths. `query_lower` must already be lowercased (and non-empty).
pub(crate) fn track_dto_matches_query(dto: &SimpleTrackDto, query_lower: &str) -> bool {
    dto.title.to_lowercase().contains(query_lower)
        || dto
            .artists
            .iter()
            .any(|a| a.name.to_lowercase().contains(query_lower))
        || dto
            .album
            .as_ref()
            .is_some_and(|a| a.to_lowercase().contains(query_lower))
}

/// Unified track-DTO source: DB metadata first, missing ids topped up via
/// `fetch_tracks` in 50-chunks (saved back to DB), liked/disliked flags from
/// the current `LikedCache` snapshot. Output order == input `track_ids`
/// order; ids with no metadata anywhere are skipped.
pub(crate) async fn build_track_dtos(
    ctx: &AppContext,
    track_ids: Vec<String>,
) -> Vec<SimpleTrackDto> {
    if track_ids.is_empty() {
        return Vec::new();
    }

    // Normalize to base ids: LikedCache/DB/metadata are all keyed by base
    // id, while callers may pass composite "id:album" ids (see `extract_ids`).
    let base_ids: Vec<String> = track_ids
        .iter()
        .map(|id| id.to_base_id().to_string())
        .collect();

    // 1. Fetch available metadata from DB
    let mut metadata_map = foldhash::HashMap::new();
    if let Ok(metadata) = ctx
        .core
        .db
        .lock()
        .await
        .get_track_metadata(&base_ids)
        .await
    {
        for m in metadata {
            metadata_map.insert(m.id.clone(), m);
        }
    }

    // 2. Fetch missing metadata if any
    let missing_ids: Vec<String> = base_ids
        .iter()
        .filter(|id| match metadata_map.get(*id) {
            None => true,
            Some(m) => m.artists.is_empty() || m.artists.iter().any(|a| a.id.is_empty()),
        })
        .cloned()
        .collect();

    fetch_and_save_missing_metadata(ctx, missing_ids, &mut metadata_map).await;

    // 3. Build DTOs in the caller's order (`base_ids` are already normalized,
    // so the snapshot lookup is a plain `contains`).
    let (liked_set, disliked_set) = ctx.audio.state.read().await.liked.snapshot();
    base_ids
        .into_iter()
        .filter_map(|id| {
            metadata_map.remove(&id).map(|m| {
                let is_liked = liked_set.contains(&id);
                let is_disliked = disliked_set.contains(&id);
                metadata_to_dto(m, is_liked, is_disliked)
            })
        })
        .collect()
}

/// Unified builder for paths that already hold a fresh server `Track` payload
/// (e.g. playlist details): seeds the metadata DB from it so [`build_track_dtos`]
/// serves fresh rows without an extra `fetch_tracks` round-trip, then
/// delegates. Output order == input order.
pub(crate) async fn build_track_dtos_from_server_tracks(
    ctx: &AppContext,
    tracks: Vec<yandex_music::model::track::Track>,
) -> Vec<SimpleTrackDto> {
    if tracks.is_empty() {
        return Vec::new();
    }
    let ids: Vec<String> = tracks.iter().map(|t| t.id.clone()).collect();
    {
        let mut db = ctx.core.db.lock().await;
        for t in tracks {
            let m = yandex_track_to_metadata(t);
            if let Err(e) = db.upsert_track_metadata(m).await {
                tracing::error!("Failed to upsert track metadata in DB: {:?}", e);
            }
        }
    }
    build_track_dtos(ctx, ids).await
}

/// Kind of the system «Мне нравится» playlist.
///
/// The `Playlist` model (`yandex-music 0.7.0`) carries no `is_favorite` flag —
/// `visibility` is a plain string, `owner` just a `User` — so the only marker
/// is the well-known kind: [`ApiService::fetch_liked_tracks`] hardcodes
/// `kinds([3])` for the likes collection.
pub(crate) const FAVORITE_PLAYLIST_KIND: u32 = 3;

/// Resolves `(uid, kind)` of the «Мне нравится» system playlist via
/// `fetch_all_playlists`: prefers `kind == 3`, falls back to a title
/// heuristic. `None` when the list cannot be fetched or no candidate matches
/// (caller falls back to [`liked_tracks_stream`]).
pub(crate) async fn resolve_favorite_playlist_kind(ctx: &AppContext) -> Option<(i64, u32)> {
    match ctx.core.api.fetch_all_playlists().await {
        Ok(playlists) => {
            if let Some(p) = playlists.iter().find(|p| p.kind == FAVORITE_PLAYLIST_KIND) {
                return Some((p.uid as i64, p.kind));
            }
            playlists
                .iter()
                .find(|p| p.title.trim().to_lowercase().contains("мне нравится"))
                .map(|p| (p.uid as i64, p.kind))
        }
        Err(e) => {
            tracing::error!("Failed to fetch playlists for favorite resolve: {:?}", e);
            None
        }
    }
}

/// Favorite-tracks details through the same [`crate::api::content::get_playlist_details`]
/// path as any regular playlist (the web client treats «Избранное» as an
/// ordinary playlist resolved via `playlistUuid`). `None` → fall back to
/// [`liked_tracks_stream`].
pub(crate) async fn get_favorite_playlist_details(
    ctx: &AppContext,
    query: Option<String>,
) -> Option<PlaylistDetailsDto> {
    let (uid, kind) = resolve_favorite_playlist_kind(ctx).await?;
    crate::api::content::get_playlist_details(ctx, uid, kind, query).await
}

pub async fn liked_tracks_stream(
    ctx: &AppContext,
    sink: StreamSink<Vec<SimpleTrackDto>>,
    query: Option<String>,
) {
    let mut changed_rx = ctx.audio.signals.library_changed_rx.clone();
    let query_lower = query
        .as_ref()
        .filter(|q| !q.trim().is_empty())
        .map(|q| q.to_lowercase());

    // Last sequence actually sent (unfiltered path only). `library_changed`
    // fires on any library mutation (playlists, albums, ...), so skip the
    // full DTO rebuild when the liked set itself is untouched — same idea
    // as the original client's revision-gated `collection/sync`.
    // Trade-off: metadata-only changes (e.g. a cover refresh with identical
    // ids) don't resend until the next liked-set change.
    let mut last_sent_ids: Vec<String> = Vec::new();
    let mut last_sent_disliked: foldhash::HashSet<String> = foldhash::HashSet::default();
    let mut last_sent_count: usize = 0;
    let mut first_run = true;

    // Pull-to-refresh resubscribes: without a fresh server snapshot the
    // rebuild below would just re-emit the stale LikedCache (likes added
    // in another client appear only after restart / the 300s worker sync).
    // Freshen inline; on failure sync keeps the cached snapshot, so this
    // stays offline-safe. Filtered (search) subscriptions skip the network
    // round-trip and read the snapshot.
    if query_lower.is_none() {
        crate::audio::system::AudioSystem::sync_liked_collection_with(
            ctx.core.api.clone(),
            ctx.audio.state.clone(),
            ctx.audio.signals.clone(),
            ctx.core.db.clone(),
        )
        .await;
    }

    loop {
        let (liked_ids, disliked_ids_set) =
            ctx.audio.state.read().await.liked.ordered_snapshot();

        // If the previous sequence had ids but sent zero DTOs (metadata was
        // missing from DB/network at the time), don't skip: a later
        // `library_changed` (e.g. playlist rename, SyncLiked completion) is
        // the only chance to resend once metadata becomes available.
        let prev_starved = !last_sent_ids.is_empty() && last_sent_count == 0;

        if !first_run
            && !prev_starved
            && query_lower.is_none()
            && liked_ids == last_sent_ids
            && disliked_ids_set == last_sent_disliked
        {
            // Unrelated library change — keep the current UI list as is.
            if changed_rx.changed().await.is_err() {
                break;
            }
            continue;
        }
        last_sent_ids = liked_ids.clone();
        last_sent_disliked = disliked_ids_set.clone();
        first_run = false;

        // ALWAYS send an empty vec to signal a new data sequence (for reset/replacement)
        // This ensures the frontend knows that a new sequence of chunks is starting.
        if sink.add(vec![]).is_err() {
            return;
        }

        if liked_ids.is_empty() {
            // If the list is truly empty, we send another empty vec as the data itself.
            if sink.add(vec![]).is_err() {
                return;
            }
            last_sent_count = 0;

            // If local is empty and not searching, might need sync
            if query_lower.is_none() {
                let _ = ctx
                    .audio
                    .tx
                    .send(crate::audio::commands::AudioMessage::SyncLiked)
                    .await;
            }
        } else {
            // Unified source: DB metadata + fetch_tracks(50) top-up + snapshot
            // flags, in LikedCache order. Filtered with the shared matcher.
            let all_dtos = build_track_dtos(ctx, liked_ids).await;

            // 3. Filter and stream DTOs in chunks
            let mut dtos = Vec::with_capacity(50);
            let mut sent_count: usize = 0;

            for dto in all_dtos.into_iter().filter(|d| {
                query_lower
                    .as_ref()
                    .is_none_or(|q| track_dto_matches_query(d, q))
            }) {
                dtos.push(dto);

                if dtos.len() >= 50 {
                    sent_count += dtos.len();
                    if sink
                        .add(std::mem::replace(&mut dtos, Vec::with_capacity(50)))
                        .is_err()
                    {
                        return;
                    }
                }
            }

            if !dtos.is_empty() {
                sent_count += dtos.len();
                if sink.add(dtos).is_err() {
                    return;
                }
            }
            // Unfiltered path only: remember how many DTOs were actually
            // sent so a starved (0-DTO) sequence is retried on the next
            // `library_changed` instead of being skipped forever.
            if query_lower.is_none() {
                last_sent_count = sent_count;
            }

            // If we were searching but found nothing, send empty list to show "No results"
            if sent_count == 0 && query_lower.is_some() && sink.add(vec![]).is_err() {
                return;
            }
        }

        // Wait for signal changes
        if changed_rx.changed().await.is_err() {
            break;
        }
    }
}
