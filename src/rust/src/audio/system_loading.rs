//! Loading helpers for `super::system::AudioSystem`.
//!
//! Free functions with explicit parameters: offline single-track builds
//! plus one unified offline-or-remote resolver parametrised by
//! [`SingleTrackSource`] (flag for the album/playlist/liked branches).

use crate::audio::commands::AudioMessage;
use crate::audio::queue::PlaybackContext;
use crate::audio::state::SystemState;
use crate::audio::stream_manager::StreamManager;
use crate::audio::yandex::YandexProvider;
use im::Vector;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock, mpsc};
use yandex_music::model::track::Track;

/// Which single-track entry point is being resolved.
pub enum SingleTrackSource {
    AlbumTrack { album_id: u32 },
    PlaylistTrack { kind: u32 },
    Liked,
}

/// Single-track queue from locally cached (DB) metadata, no network.
pub async fn build_single_track_offline(
    db: &Arc<Mutex<crate::db::AppDatabase>>,
    track_id: &str,
) -> Option<(Vector<Track>, usize)> {
    let ids = vec![track_id.to_string()];
    let metadata = db.lock().await.get_track_metadata(&ids).await.ok()?;
    let m = metadata.into_iter().find(|m| m.id == track_id)?;
    let mut tracks = Vector::new();
    tracks.push_back(crate::util::track::track_from_metadata(&m));
    Some((tracks, 0))
}

/// Liked-track queue rebuilt from local liked order + cached metadata.
pub async fn build_local_liked_context(
    db: &Arc<Mutex<crate::db::AppDatabase>>,
    state: &Arc<RwLock<SystemState>>,
    track_id: &str,
) -> Option<(Vector<Track>, usize)> {
    let (liked_ids, _) = state.read().await.liked.ordered_snapshot();
    if liked_ids.is_empty() {
        return None;
    }

    let metadata = db
        .lock()
        .await
        .get_track_metadata(&liked_ids)
        .await
        .ok()?;
    let mut metadata_map: foldhash::HashMap<String, crate::storage::db::TrackMetadata> = {
        use foldhash::HashMapExt;
        foldhash::HashMap::new()
    };
    for m in metadata {
        metadata_map.insert(m.id.clone(), m);
    }

    let mut tracks = Vector::new();
    let mut index = None;
    for id in &liked_ids {
        if let Some(m) = metadata_map.remove(id) {
            if id == track_id {
                index = Some(tracks.len());
            }
            tracks.push_back(crate::util::track::track_from_metadata(&m));
        }
    }

    Some((tracks, index?))
}

async fn fetch_remote_for_source(
    yandex: &YandexProvider,
    source: &SingleTrackSource,
    tid: &str,
) -> std::result::Result<(PlaybackContext, Vector<Track>, usize), String> {
    match source {
        SingleTrackSource::AlbumTrack { album_id } => {
            yandex
                .fetch_album_context(*album_id, Some(tid.to_string()))
                .await
                .map_err(|e| format!("Failed to load album: {e}"))
        }
        SingleTrackSource::PlaylistTrack { kind } => {
            yandex
                .fetch_playlist_context(*kind, Some(tid.to_string()))
                .await
                .map_err(|e| format!("Failed to load playlist track: {e}"))
        }
        SingleTrackSource::Liked => {
            yandex
                .fetch_liked_context(Some(tid.to_string()))
                .await
                .map_err(|e| format!("Failed to load liked track: {e}"))
        }
    }
}

/// Unified offline-or-remote resolution; sends `LoadContext` or
/// `ContextFetched` back to the actor. Differences are driven by `source`.
/// Takes the full actor dependency set to replace three ~45-line copies.
#[allow(clippy::too_many_arguments)]
pub async fn resolve_single_track_offline_or_remote(
    source: SingleTrackSource,
    tid: String,
    stream_manager: Arc<StreamManager>,
    db: Arc<Mutex<crate::db::AppDatabase>>,
    state: Option<Arc<RwLock<SystemState>>>,
    yandex: YandexProvider,
    tx: mpsc::Sender<AudioMessage>,
    generation: u64,
) {
    let local_ctx = if stream_manager.is_track_offline(&tid).await {
        match &source {
            SingleTrackSource::Liked => match &state {
                Some(s) => build_local_liked_context(&db, s, &tid).await,
                None => None,
            },
            SingleTrackSource::AlbumTrack { .. } | SingleTrackSource::PlaylistTrack { .. } => {
                build_single_track_offline(&db, &tid).await
            }
        }
    } else {
        None
    };
    if let Some((tracks, index)) = local_ctx {
        let _ = tx
            .send(AudioMessage::LoadContext(
                PlaybackContext::Standalone,
                tracks,
                index,
            ))
            .await;
        return;
    }
    let result = fetch_remote_for_source(&yandex, &source, &tid).await;
    let _ = tx
        .send(AudioMessage::ContextFetched {
            generation,
            result,
        })
        .await;
}
