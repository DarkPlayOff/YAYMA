use futures::future::join_all;
use yandex_music::model::artist::Artist;
use yandex_music::model::playlist::PlaylistTracks;
use yandex_music::model::track::Track;

/// Builds a minimal `Track` from locally cached DB metadata, for offline playback
/// where we can't hit the network to fetch the full track object.
pub fn track_from_metadata(m: &crate::storage::db::TrackMetadata) -> Track {
    let artists: Vec<Artist> = m
        .artists
        .iter()
        .map(|a| Artist {
            id: Some(a.id.clone()),
            error: None,
            reason: None,
            name: Some(a.name.clone()),
            cover: None,
            various: None,
            composer: None,
            genres: None,
            og_image: None,
            op_image: None,
            counts: None,
            available: None,
            ratings: None,
            links: Vec::new(),
            tickets_available: None,
            likes_count: None,
            popular_tracks: Vec::new(),
            regions: Vec::new(),
            decomposed: Vec::new(),
            description: None,
            countries: Vec::new(),
            en_wikipedia_link: None,
            db_aliases: Vec::new(),
            aliases: Vec::new(),
            init_date: None,
            end_date: None,
        })
        .collect();

    Track {
        id: m.id.clone(),
        title: Some(m.title.clone()),
        available: Some(true),
        artists,
        albums: Vec::new(),
        available_for_premium_users: None,
        lyrics_available: None,
        best: None,
        real_id: m.id.clone(),
        og_image: None,
        item_type: None,
        cover_uri: m.cover_url.clone(),
        major: None,
        duration: Some(std::time::Duration::from_millis(m.duration_ms)),
        storage_dir: None,
        file_size: None,
        substituted: None,
        matched_track: None,
        normalization: Vec::new(),
        error: None,
        can_publish: None,
        state: None,
        desired_visibility: None,
        filename: None,
        user_info: None,
        meta_data: None,
        regions: Vec::new(),
        available_as_rbt: None,
        content_warning: None,
        explicit: None,
        preview_duration: None,
        available_full_without_permission: None,
        version: m.version.clone(),
        remember_position: None,
        background_video_uri: None,
        short_description: None,
        is_suitable_for_children: None,
        track_source: None,
        available_for_options: Vec::new(),
        r128: None,
        lyrics_info: None,
        track_sharing_flag: None,
        disclaimers: Vec::new(),
        derived_colors: None,
        fade: None,
        special_audio_resources: Vec::new(),
        player_id: None,
        play_count: None,
    }
}

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
