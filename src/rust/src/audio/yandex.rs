use crate::audio::queue::PlaybackContext;
use crate::audio::signals::AudioSignals;
use crate::http::ApiService;
use im::Vector;
use std::sync::Arc;
use yandex_music::model::playlist::PlaylistTracks;
use yandex_music::model::track::Track;

type ContextResult =
    Result<(PlaybackContext, Vector<Track>, usize), Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone)]
pub struct YandexProvider {
    pub api: Arc<ApiService>,
    signals: AudioSignals,
}

impl YandexProvider {
    pub fn new(api: Arc<ApiService>, signals: AudioSignals) -> Self {
        Self { api, signals }
    }

    async fn build_context(
        &self,
        tracks: Vec<Track>,
        track_id: Option<String>,
        make_context: impl FnOnce() -> PlaybackContext,
        error_msg: &'static str,
    ) -> ContextResult {
        if tracks.is_empty() {
            return Err(error_msg.into());
        }
        let index = track_id
            .and_then(|tid| tracks.iter().position(|t| t.id == tid))
            .unwrap_or(0);
        Ok((make_context(), Vector::from(tracks), index))
    }

    async fn fetch_playlist_generic(
        &self,
        mut playlist: yandex_music::model::playlist::Playlist,
        track_id: Option<String>,
        error_msg: &'static str,
    ) -> ContextResult {
        if let Some(tracks_enum) = playlist.tracks.take() {
            // Partial playlist responses contain only IDs.  Resolve the first
            // API-sized page so playback can start immediately, while keeping
            // the original Partial list in the context for QueueManager to
            // lazily resolve as the user approaches its end.
            if let PlaylistTracks::Partial(partial) = tracks_enum.clone() {
                let target_index = track_id
                    .as_ref()
                    .and_then(|id| partial.iter().position(|p| p.id == *id));
                // Resolve a window around the target so playback starts fast
                // even deep inside a big playlist; the rest stays lazy.
                // NOTE: QueueManager derives the lazy tail as
                // `all_ids.skip(loaded_count)`, so the context playlist is
                // trimmed to `ids[window_start..]` — tracks before the window
                // are dropped (Prev limited to the window) but the pending
                // tail stays exact.
                let (window_start, window): (usize, Vec<_>) = match target_index {
                    Some(idx) if idx >= crate::audio::fetcher::FETCH_BATCH_SIZE => {
                        let half = crate::audio::fetcher::FETCH_BATCH_SIZE / 2;
                        let start = idx.saturating_sub(half);
                        let end = (start + crate::audio::fetcher::FETCH_BATCH_SIZE)
                            .min(partial.len());
                        (start, partial[start..end].to_vec())
                    }
                    _ => (
                        0,
                        partial
                            .iter()
                            .take(crate::audio::fetcher::FETCH_BATCH_SIZE)
                            .cloned()
                            .collect(),
                    ),
                };
                {
                    let initial = crate::util::track::fetch_full_tracks(
                        &self.api,
                        PlaylistTracks::Partial(window),
                    )
                    .await;
                    if !initial.is_empty() {
                        // Trim context so pending-ids math stays correct.
                        playlist.tracks = Some(PlaylistTracks::Partial(
                            partial[window_start..].to_vec(),
                        ));
                        let index_in_window = track_id
                            .as_ref()
                            .and_then(|tid| initial.iter().position(|t| &t.id == tid))
                            .or_else(|| {
                                target_index.map(|idx| {
                                    (idx - window_start).min(initial.len().saturating_sub(1))
                                })
                            })
                            .unwrap_or(0);
                        let found = track_id.as_ref().is_none_or(|tid| {
                            initial.iter().any(|t| &t.id == tid)
                        });
                        if found {
                            return Ok((
                                PlaybackContext::Playlist(playlist),
                                Vector::from(initial),
                                index_in_window,
                            ));
                        }
                    }
                }
            }
            let tracks = crate::util::track::fetch_full_tracks(&self.api, tracks_enum).await;
            return self
                .build_context(
                    tracks,
                    track_id,
                    || PlaybackContext::Playlist(playlist),
                    error_msg,
                )
                .await;
        }
        Err(error_msg.into())
    }

    pub async fn fetch_playlist_context(
        &self,
        kind: u32,
        track_id: Option<String>,
    ) -> ContextResult {
        let playlist = self.api.fetch_playlist(kind).await?;
        self.fetch_playlist_generic(
            playlist,
            track_id,
            "Playlist is empty or could not be loaded",
        )
        .await
    }

    pub async fn fetch_liked_context(&self, track_id: Option<String>) -> ContextResult {
        let playlist = self.api.fetch_liked_tracks().await?;
        self.fetch_playlist_generic(
            playlist,
            track_id,
            "Liked tracks are empty or could not be loaded",
        )
        .await
    }

    pub async fn fetch_album_context(
        &self,
        album_id: u32,
        track_id: Option<String>,
    ) -> ContextResult {
        let album = self.api.fetch_album_with_tracks(album_id).await?;
        let tracks: Vec<_> = album.volumes.iter().flatten().cloned().collect();
        self.build_context(
            tracks,
            track_id,
            || PlaybackContext::Album(album),
            "Album is empty or could not be loaded",
        )
        .await
    }

    pub async fn fetch_wave_context(&self, seeds: Vec<String>) -> ContextResult {
        self.signals.current_wave_seeds.set(seeds.clone());
        let clean_seeds: Vec<String> = seeds
            .iter()
            .map(|s| {
                if s.starts_with("track:") {
                    s.split(':').take(2).collect::<Vec<_>>().join(":")
                } else {
                    s.clone()
                }
            })
            .collect();

        let session = self.api.create_session(clean_seeds).await?;
        let tracks: Vec<_> = session.sequence.iter().map(|s| s.track.clone()).collect();
        self.build_context(
            tracks,
            None,
            || PlaybackContext::Wave(session),
            "Wave session is empty or could not be started",
        )
        .await
    }
}
