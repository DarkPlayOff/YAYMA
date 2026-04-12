use crate::audio::events::Event;
use crate::audio::queue::PlaybackContext;
use crate::audio::signals::AudioSignals;
use crate::http::ApiService;
use flume::Sender;
use im::Vector;
use std::sync::Arc;
use yandex_music::model::track::Track;

type ContextResult =
    Result<(PlaybackContext, Vector<Track>, usize), Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone)]
pub struct YandexProvider {
    pub api: Arc<ApiService>,
    signals: AudioSignals,
}

impl YandexProvider {
    pub fn new(api: Arc<ApiService>, _event_tx: Sender<Event>, signals: AudioSignals) -> Self {
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
        let session = self.api.create_session(seeds).await?;
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
