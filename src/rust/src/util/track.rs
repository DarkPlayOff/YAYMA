use futures::future::join_all;
use yandex_music::model::playlist::PlaylistTracks;
use yandex_music::model::track::Track;

pub trait CleanId {
    fn to_base_id(&self) -> &str;
}

impl CleanId for String {
    fn to_base_id(&self) -> &str {
        self.split(':').next().unwrap_or(self)
    }
}

impl CleanId for str {
    fn to_base_id(&self) -> &str {
        self.split(':').next().unwrap_or(self)
    }
}

pub fn extract_ids(playlist_tracks: &PlaylistTracks) -> Vec<String> {
    match playlist_tracks {
        PlaylistTracks::Full(tracks) => tracks
            .iter()
            .map(|t| {
                if let Some(album_id) = t.albums.first().and_then(|a| a.id) {
                    format!("{}:{}", t.id, album_id)
                } else {
                    t.id.clone()
                }
            })
            .collect(),
        PlaylistTracks::WithInfo(tracks) => tracks
            .iter()
            .map(|t| {
                if let Some(album_id) = t.track.albums.first().and_then(|a| a.id) {
                    format!("{}:{}", t.track.id, album_id)
                } else {
                    t.track.id.clone()
                }
            })
            .collect(),
        PlaylistTracks::Partial(partial) => partial
            .iter()
            .map(|p| {
                if let Some(album_id) = p.album_id {
                    format!("{}:{}", p.id, album_id)
                } else {
                    p.id.clone()
                }
            })
            .collect(),
    }
}

/// Asynchronously retrieves full track data from a PlaylistTracks enum.
/// If the data is partial, it performs a bulk fetch through the API in parallel chunks.
pub async fn fetch_full_tracks(
    api: &crate::http::ApiService,
    playlist_tracks: PlaylistTracks,
) -> Vec<Track> {
    match playlist_tracks {
        PlaylistTracks::Full(tracks) => tracks,
        PlaylistTracks::WithInfo(tracks) => tracks.into_iter().map(|t| t.track).collect(),
        PlaylistTracks::Partial(partial) => {
            let ids: Vec<String> = partial.into_iter().map(|p| p.id.to_string()).collect();

            // Prepare fetch tasks for parallel execution
            let mut fetch_tasks = Vec::new();

            // Fetch tracks in chunks of 100 to stay within API limits
            for chunk in ids.chunks(100) {
                let chunk_ids = chunk.to_vec();
                fetch_tasks.push(async move { api.fetch_tracks(chunk_ids).await });
            }

            // Execute all requests in parallel and collect results
            let results = join_all(fetch_tasks).await;

            let mut fetched = Vec::new();
            for tracks in results.into_iter().flatten() {
                fetched.extend(tracks);
            }
            fetched
        }
    }
}
