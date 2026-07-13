use crate::api::models::AudioQuality;
use chrono::Utc;
use parking_lot::RwLock;
use serde_json;
use std::sync::Arc;
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use yandex_music::{
    YandexMusicClient,
    // ... (rest of imports remains similar, but I need to provide full block)
    api::{
        album::{
            add_liked_album::AddLikedAlbumOptions, get_album::GetAlbumOptions,
            remove_liked_album::RemoveLikedAlbumOptions,
        },
        artist::{
            add_disliked_artist::AddDislikedArtistOptions, add_liked_artist::AddLikedArtistOptions,
            get_artist::GetArtistOptions, get_artist_albums::GetArtistAlbumsOptions,
            get_artist_tracks::ArtistTracksOptions,
            remove_disliked_artist::RemoveDislikedArtistOptions,
            remove_liked_artist::RemoveLikedArtistOptions,
        },
        collection::sync::{CollectionSyncOption, CollectionSyncOptions},
        playlist::{
            add_liked_playlist::AddLikedPlaylistOptions,
            change_playlist_visibility::ChangePlaylistVisibilityOptions,
            create_playlist::CreatePlaylistOptions, delete_playlist::DeletePlaylistOptions,
            get_all_playlists::GetAllPlaylistsOptions, get_playlists::GetPlaylistsOptions,
            modify_playlist::ModifyPlaylistOptions,
            remove_liked_playlist::RemoveLikedPlaylistOptions,
            rename_playlist::RenamePlaylistOptions,
        },
        rotor::{
            create_session::CreateSessionOptions, get_session_tracks::GetSessionTracksOptions,
            get_station_tracks::GetStationTracksOptions,
            send_station_feedback::SendStationFeedbackOptions,
        },
        search::get_search::SearchOptions,
        track::{
            add_disliked_tracks::AddDislikedTracksOptions, add_liked_tracks::AddLikedTracksOptions,
            get_lyrics::GetLyricsOptions,
            get_similar_tracks::GetSimilarTracksOptions, get_tracks::GetTracksOptions,
            remove_disliked_tracks::RemoveDislikedTracksOptions,
            remove_liked_tracks::RemoveLikedTracksOptions,
        },
    },
    model::{
        album::Album,
        artist::Artist,
        collection::Collection,
        info::{file_info::Quality, lyrics::LyricsFormat, pager::Pager},
        playlist::{
            Playlist,
            modify::{Diff, DiffOp},
        },
        rotor::{
            Rotor,
            feedback::{StationFeedback, StationFeedbackEvent},
            session::Session,
            station::StationTracks,
        },
        search::Search,
        track::{Track, TrackShort},
    },
};

pub trait SessionExt {
    fn station_id(&self) -> &str;
    fn source_id(&self) -> &str;
}

impl SessionExt for Session {
    fn station_id(&self) -> &str {
        self.radio_session_id
            .as_deref()
            .or(self.wave.as_ref().map(|w| w.station_id.as_str()))
            .unwrap_or("user:onyourwave")
    }

    fn source_id(&self) -> &str {
        self.wave
            .as_ref()
            .map(|w| w.id_for_from.as_str())
            .unwrap_or("rotor")
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct YandexResponse<T> {
    pub result: T,
}

#[derive(Debug, serde::Deserialize)]
pub struct UgcUploadInfo {
    pub host: String,
}

/// HMAC key Yandex validates `get-file-info` signatures against. The
/// `yandex-music` crate's bundled key (`p93jhgh689SBReK6ghtw62`) is no longer
/// accepted — every request comes back 403 `track-download-info-error` /
/// `not-allowed`. This key was extracted from the official desktop app's
/// Windows build; we always identify as that client via the
/// `X-Yandex-Music-Client` header below, so we always sign with its key
/// regardless of the host OS we're actually running on.
const FILE_INFO_SIGN_KEY: &str = "kzqU4XhfCaY6B6JTHODeq5";

/// Reimplementation of `yandex_music::api::utils::create_file_info_sign`
/// using [`FILE_INFO_SIGN_KEY`] instead of the crate's stale key.
fn create_file_info_sign(
    track_id: &str,
    quality: &str,
    codecs: &str,
    transport: &str,
) -> (String, String) {
    use base64::Engine;
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        .to_string();
    let msg = format!("{}{}{}{}{}", ts, track_id, quality, codecs, transport);
    let mut mac = Hmac::<Sha256>::new_from_slice(FILE_INFO_SIGN_KEY.as_bytes())
        .expect("HMAC accepts a key of any length");
    mac.update(msg.as_bytes());
    let digest = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());
    // Yandex's own signer drops the trailing base64 padding/char to match.
    let sign = digest[..digest.len() - 1].to_string();
    (ts, sign)
}

pub struct ApiService {
    pub client: Arc<YandexMusicClient>,
    pub http_client: reqwest::Client,
    user_id: u64,
    pub quality: RwLock<AudioQuality>,
}

impl ApiService {
    pub async fn new(token: String, user_id: Option<u64>) -> Result<Self> {
        let quality = RwLock::new(AudioQuality::default());

        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("OAuth {}", token))?,
        );
        headers.insert(
            "X-Yandex-Music-Client",
            HeaderValue::from_str("YandexMusicDesktopAppWindows/5.95.0")?,
        );
        headers.insert("Accept-Language", HeaderValue::from_str("ru")?);
        headers.insert("Accept", HeaderValue::from_str("*/*")?);
        // Deliberately NOT setting X-Yandex-Music-Without-Invocation-Info here:
        // it strips `invocationInfo`/`exec-duration-millis` from every
        // response, which breaks the crate's strict typed deserialization
        // for account/playlists/etc. get-file-info is parsed manually below
        // and already tolerates responses with or without that wrapper.
        headers.insert(
            "Origin",
            HeaderValue::from_str("music-application://desktop")?,
        );

        let http_client = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 YandexMusic/5.95.0")
            .default_headers(headers.clone())
            .brotli(true)
            .build()?;

        // Always build our own client rather than accepting a pre-built one:
        // the `get-file-info` sign key is tied to the `X-Yandex-Music-Client`
        // identity above, and a client built via the crate's own
        // `YandexMusicClient::builder` defaults to a different client id
        // (`DEFAULT_CLIENT_ID`), which Yandex rejects as a signature/identity
        // mismatch (403 `track-download-info-error`/`not-allowed`) even
        // though the token itself is perfectly valid.
        let client = Arc::new(YandexMusicClient::from_client(http_client.clone()));

        let user_id = if let Some(uid) = user_id {
            uid
        } else {
            client
                .get_account_status()
                .await?
                .account
                .uid
                .ok_or_else(|| {
                    Box::<dyn std::error::Error + Send + Sync>::from("No user id found")
                })?
        };

        Ok(Self {
            client,
            http_client,
            user_id,
            quality,
        })
    }

    pub fn current_user_id(&self) -> u64 {
        self.user_id
    }

    pub async fn fetch_ugc_upload_info(&self, kind: u32, name: &str) -> Result<String> {
        Ok(self.http_client.post(format!("https://api.music.yandex.ru/loader/upload-url?uid={0}&playlist-id={0}:{1}&path={2}", self.user_id, kind, urlencoding::encode(name)))
            .send().await?.json::<serde_json::Value>().await?["post-target"]
            .as_str().ok_or("No target")?.to_string())
    }

    pub async fn upload_ugc_track(&self, url: &str, path: &str) -> Result<String> {
        let name = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("t.mp3");
        let form = reqwest::multipart::Form::new().part(
            "file",
            reqwest::multipart::Part::bytes(tokio::fs::read(path).await?)
                .file_name(name.to_string())
                .mime_str("audio/mpeg")?,
        );
        let v = self
            .http_client
            .post(url)
            .multipart(form)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;
        let id = v["id"].as_str().map(|s| s.to_string()).unwrap_or_else(|| {
            if v["result"] == "CREATED" {
                "CREATED_PENDING".into()
            } else {
                v.to_string()
            }
        });
        Ok(id)
    }

    pub fn set_quality(&self, quality: AudioQuality) {
        *self.quality.write() = quality;
    }

    pub fn get_quality(&self) -> AudioQuality {
        *self.quality.read()
    }

    pub async fn search(&self, query: &str) -> Result<Search> {
        let opts = SearchOptions::new(query);
        Ok(self.client.search(&opts).await?)
    }

    pub async fn search_paginated(&self, query: &str, page: u32) -> Result<Search> {
        let opts = SearchOptions::new(query).page(page);
        Ok(self.client.search(&opts).await?)
    }

    pub async fn fetch_liked_tracks(&self) -> Result<Playlist> {
        self.fetch_first(
            self.client.get_playlists(
                &GetPlaylistsOptions::new(self.user_id)
                    .kinds([3u32])
                    .with_tracks(true),
            ),
        )
        .await
    }

    pub async fn fetch_all_playlists(&self) -> Result<Vec<Playlist>> {
        let opts = GetAllPlaylistsOptions::new(self.user_id);
        Ok(self.client.get_all_playlists(&opts).await?)
    }

    pub async fn fetch_liked_albums(&self) -> Result<Vec<Album>> {
        let url = format!(
            "https://api.music.yandex.ru/users/{}/likes/albums?rich=true",
            self.user_id
        );
        let body: serde_json::Value = self.http_client.get(url).send().await?.json().await?;
        Ok(Self::extract_liked(&body, "albums", "album"))
    }

    pub async fn fetch_liked_artists(&self) -> Result<Vec<Artist>> {
        let url = format!(
            "https://api.music.yandex.ru/users/{}/likes/artists?with-timestamps=false",
            self.user_id
        );
        let body: serde_json::Value = self.http_client.get(url).send().await?.json().await?;
        Ok(Self::extract_liked(&body, "artists", "artist"))
    }

    /// Parses Yandex "likes" responses. The payload may arrive as a top-level array,
    /// `result: [..]`, `result: { <plural>: [..] }`, or `result: { likes: [..] }`.
    /// Each entry may be the object itself or wrapped as `{ id, timestamp, <singular>: {..} }`.
    fn extract_liked<T: serde::de::DeserializeOwned>(
        body: &serde_json::Value,
        plural_key: &str,
        singular_key: &str,
    ) -> Vec<T> {
        if let Some(items) = Self::liked_items(body, plural_key) {
            items
                .iter()
                .filter_map(|item| {
                    let value = if item.get(singular_key).is_some() {
                        &item[singular_key]
                    } else {
                        item
                    };
                    serde_json::from_value::<T>(value.clone()).ok()
                })
                .collect()
        } else {
            vec![]
        }
    }

    fn liked_items<'a>(
        body: &'a serde_json::Value,
        plural_key: &str,
    ) -> Option<&'a Vec<serde_json::Value>> {
        let result = &body["result"];
        body.as_array()
            .or_else(|| result.as_array())
            .or_else(|| result[plural_key].as_array())
            .or_else(|| result["likes"].as_array())
            .or_else(|| result["library"][plural_key].as_array())
    }

    pub async fn fetch_playlist(&self, kind: u32) -> Result<Playlist> {
        self.fetch_first(
            self.client.get_playlists(
                &GetPlaylistsOptions::new(self.user_id)
                    .kinds([kind])
                    .with_tracks(true),
            ),
        )
        .await
    }

    pub async fn fetch_playlist_bare(&self, kind: u32) -> Result<Playlist> {
        self.fetch_first(
            self.client.get_playlists(
                &GetPlaylistsOptions::new(self.user_id)
                    .kinds([kind])
                    .with_tracks(true)
                    .rich_tracks(false),
            ),
        )
        .await
    }

    pub async fn fetch_playlists(&self, kinds: Vec<u32>) -> Result<Playlist> {
        self.fetch_first(
            self.client.get_playlists(
                &GetPlaylistsOptions::new(self.user_id)
                    .kinds(kinds)
                    .with_tracks(true),
            ),
        )
        .await
    }

    async fn fetch_first<T, Fut, E>(&self, fut: Fut) -> Result<T>
    where
        Fut: std::future::Future<Output = std::result::Result<Vec<T>, E>>,
        E: Into<Box<dyn std::error::Error + Send + Sync>>,
    {
        fut.await
            .map_err(|e| e.into())?
            .into_iter()
            .next()
            .ok_or_else(|| "Not found".into())
    }

    pub async fn fetch_tracks(&self, track_ids: Vec<String>) -> Result<Vec<Track>> {
        let opts = GetTracksOptions::new(track_ids);
        Ok(self.client.get_tracks(&opts).await?)
    }

    pub async fn fetch_similar_tracks(&self, track_id: String) -> Result<Vec<Track>> {
        let opts = GetSimilarTracksOptions::new(track_id);
        Ok(self.client.get_similar_tracks(&opts).await?.similar_tracks)
    }

    fn map_quality(&self, q: AudioQuality) -> Quality {
        match q {
            AudioQuality::Low => Quality::Low,
            AudioQuality::Normal => Quality::Normal,
            AudioQuality::High => Quality::Lossless,
        }
    }

    async fn fetch_track_url_custom(
        &self,
        track_id: String,
        quality: yandex_music::model::info::file_info::Quality,
        codecs: Vec<yandex_music::model::info::file_info::Codec>,
    ) -> Result<(String, String)> {
        let transport = "raw";
        let quality_str = quality.to_string();

        let mut codecs_concat = String::new();
        let mut codecs_delimited = String::new();
        for (i, codec) in codecs.iter().enumerate() {
            let s = codec.to_string();
            codecs_concat.push_str(&s);
            if i > 0 {
                codecs_delimited.push(',');
            }
            codecs_delimited.push_str(&s);
        }

        let (ts, sign) = create_file_info_sign(&track_id, &quality_str, &codecs_concat, transport);

        let url = format!(
            "https://api.music.yandex.net:443/get-file-info?ts={}&trackId={}&quality={}&codecs={}&transports={}&sign={}",
            ts, track_id, quality_str, codecs_delimited, transport, sign
        );

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct CustomTrackFileInfo {
            pub codec: String,
            pub url: Option<String>,
            pub urls: Option<Vec<String>>,
        }

        impl CustomTrackFileInfo {
            /// `url` is the primary CDN host; `urls` are mirrors. Some
            /// responses only populate one or the other.
            fn pick_url(&self) -> Option<String> {
                self.url
                    .clone()
                    .or_else(|| self.urls.as_ref().and_then(|u| u.first().cloned()))
            }
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct CustomGetFileInfoResult {
            pub download_info: Option<CustomTrackFileInfo>,
            pub name: Option<String>,
            pub message: Option<String>,
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct CustomApiResponse {
            // Yandex normally wraps the payload in `result`, but has been
            // observed returning these fields at the top level instead.
            // Accept both shapes.
            pub result: Option<CustomGetFileInfoResult>,
            pub download_info: Option<CustomTrackFileInfo>,
            pub error: Option<yandex_music::error::YandexMusicError>,
            pub name: Option<String>,
            pub message: Option<String>,
        }

        let response_bytes = self
            .client
            .inner
            .get(&url)
            .send()
            .await?
            .bytes()
            .await?;

        let response: CustomApiResponse = match serde_json::from_slice(&response_bytes) {
            Ok(res) => res,
            Err(e) => {
                let response_text = String::from_utf8_lossy(&response_bytes);
                tracing::error!("Failed to parse get-file-info JSON: {}. Response: {}", e, response_text);
                return Err(Box::new(e));
            }
        };

        if let Some(err) = response.error {
            return Err(Box::new(yandex_music::error::ClientError::YandexMusicError { error: err }));
        }

        if let Some(name) = response.name {
            if name.contains("error") || response.message.is_some() {
                return Err(Box::new(yandex_music::error::ClientError::YandexMusicError {
                    error: yandex_music::error::YandexMusicError {
                        name,
                        message: response.message,
                    }
                }));
            }
        }

        if let Some(name) = response.result.as_ref().and_then(|r| r.name.clone()) {
            let message = response.result.as_ref().and_then(|r| r.message.clone());
            if name.contains("error") || message.is_some() {
                return Err(Box::new(yandex_music::error::ClientError::YandexMusicError {
                    error: yandex_music::error::YandexMusicError { name, message },
                }));
            }
        }

        let download_info = response
            .result
            .and_then(|r| r.download_info)
            .or(response.download_info);

        match download_info {
            Some(info) => match info.pick_url() {
                Some(url) => Ok((url, info.codec)),
                None => Err(Box::from("Missing url/urls in get-file-info downloadInfo")),
            },
            None => Err(Box::from("Missing downloadInfo in get-file-info response")),
        }
    }

    pub async fn fetch_track_url(&self, track_id: String) -> Result<(String, String)> {
        use yandex_music::model::info::file_info::Quality;

        let selected_quality = self.map_quality(self.get_quality());

        // Try the selected quality first
        match self.fetch_track_url_custom(
            track_id.clone(),
            selected_quality,
            yandex_music::model::info::file_info::Codec::all().to_vec()
        ).await {
            Ok(res) => return Ok(res),
            Err(e) => {
                tracing::warn!("Failed to fetch track {} with quality {:?}: {:?}", track_id, selected_quality, e);
            }
        }

        // If selected quality was Lossless, fall back to Normal (High)
        if selected_quality == Quality::Lossless {
            match self.fetch_track_url_custom(
                track_id.clone(),
                Quality::Normal,
                yandex_music::model::info::file_info::Codec::all().to_vec()
            ).await {
                Ok(res) => return Ok(res),
                Err(e) => {
                    tracing::warn!("Failed to fetch track {} with quality Normal: {:?}", track_id, e);
                }
            }
        }

        // If we still haven't returned, or if selected quality was Normal, fall back to Low (lowest quality)
        if selected_quality == Quality::Lossless || selected_quality == Quality::Normal {
            match self.fetch_track_url_custom(
                track_id.clone(),
                Quality::Low,
                yandex_music::model::info::file_info::Codec::all().to_vec()
            ).await {
                Ok(res) => return Ok(res),
                Err(e) => {
                    tracing::error!("Failed to fetch track {} with fallback quality Low: {:?}", track_id, e);
                    return Err(e);
                }
            }
        }

        Err(Box::from("Failed to fetch track URL with any quality"))
    }

    pub async fn fetch_track_url_for_download(&self, track_id: String) -> Result<(String, String)> {
        use yandex_music::model::info::file_info::Codec;

        // Try the same fetch as playback first (favors FLAC for Lossless quality)
        let (url, codec) = self.fetch_track_url(track_id.clone()).await?;

        // If it's already FLAC or MP3, we are happy.
        if codec.contains("flac") || codec.contains("mp3") {
            return Ok((url, codec));
        }

        // If it's AAC, we try to force MP3 instead because raw AAC doesn't support tags well.
        let quality = self.map_quality(self.get_quality());
        if let Ok(res) = self.fetch_track_url_custom(track_id, quality, vec![Codec::Mp3]).await {
            return Ok(res);
        }

        Ok((url, codec))
    }

    pub async fn fetch_track_urls_batch(
        &self,
        track_ids: Vec<String>,
    ) -> Result<Vec<(String, String, String)>> {
        let quality = self.map_quality(self.get_quality());
        let mut mapped = Vec::new();

        for track_id in track_ids {
            // Sleep for 200ms between requests to avoid concurrent rate-limiting from Yandex
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;

            match self.fetch_track_url_custom(
                track_id.clone(),
                quality,
                yandex_music::model::info::file_info::Codec::all().to_vec()
            ).await {
                Ok((url, codec)) => mapped.push((track_id, url, codec)),
                Err(e) => {
                    tracing::warn!("Batch prefetch failed for track {}: {:?}", track_id, e);
                }
            }
        }

        Ok(mapped)
    }

    pub async fn fetch_lyrics(
        &self,
        track_id: String,
        format: LyricsFormat,
    ) -> Result<Option<String>> {
        let opts = GetLyricsOptions::new(track_id, format);
        match self.client.get_lyrics(&opts).await {
            Ok(lyrics) => {
                let url = lyrics.download_url;
                let text = self.client.inner.get(url).send().await?.text().await?;
                Ok(Some(text))
            }
            Err(_) => Ok(None),
        }
    }

    pub async fn fetch_album_with_tracks(&self, album_id: u32) -> Result<Album> {
        let opts = GetAlbumOptions::new(album_id).with_tracks();
        Ok(self.client.get_album(&opts).await?)
    }

    pub async fn fetch_artist(
        &self,
        artist_id: String,
    ) -> Result<yandex_music::model::artist::Artist> {
        let opts = GetArtistOptions::new(artist_id);
        Ok(self.client.get_artist(&opts).await?.artist)
    }

    pub async fn fetch_artist_albums(
        &self,
        artist_id: String,
        page: u32,
        page_size: u32,
    ) -> Result<Vec<Album>> {
        let opts = GetArtistAlbumsOptions::new(artist_id)
            .page(page)
            .page_size(page_size);
        Ok(self.client.get_artist_albums(&opts).await?.albums)
    }

    pub async fn fetch_artist_tracks(
        &self,
        artist_id: String,
        page: u32,
        page_size: u32,
    ) -> Result<Vec<Track>> {
        let opts = ArtistTracksOptions::new(artist_id)
            .page(page)
            .page_size(page_size);
        Ok(self.client.get_artist_tracks(&opts).await?.tracks)
    }

    pub async fn fetch_artist_tracks_paginated(
        &self,
        artist_id: String,
        page: u32,
        page_size: u32,
    ) -> Result<(Vec<Track>, Pager)> {
        let opts = ArtistTracksOptions::new(artist_id)
            .page(page)
            .page_size(page_size);
        let result = self.client.get_artist_tracks(&opts).await?;
        Ok((result.tracks, result.pager))
    }

    pub async fn fetch_stations(&self) -> Result<Vec<Rotor>> {
        let opts = yandex_music::api::rotor::get_all_stations::GetAllStationsOptions::default();
        Ok(self.client.get_all_stations(&opts).await?)
    }

    pub async fn create_session(&self, seeds: Vec<String>) -> Result<Session> {
        let opts = CreateSessionOptions::new(seeds)
            .include_tracks_in_response(true)
            .include_wave_model(true)
            .interactive(true);
        Ok(self.client.create_session(opts).await?)
    }

    pub async fn get_session_tracks(
        &self,
        session_id: String,
        queue: Vec<String>,
        feedbacks: Vec<StationFeedback>,
    ) -> Result<Session> {
        let opts = GetSessionTracksOptions::new(session_id, queue).feedbacks(feedbacks);
        Ok(self.client.get_session_tracks(opts).await?)
    }

    pub async fn get_station_tracks(
        &self,
        station_id: &str,
        queue: Option<&str>,
    ) -> Result<StationTracks> {
        let mut opts = GetStationTracksOptions::new(station_id).settings2(true);
        if let Some(q) = queue {
            opts = opts.queue(q);
        }
        Ok(self.client.get_station_tracks(&opts).await?)
    }

    pub async fn send_rotor_feedback(
        &self,
        station_id: String,
        batch_id: Option<String>,
        feedback_type: &str,
        track_id: Option<String>,
        from: Option<String>,
        total_played: Option<Duration>,
    ) -> Result<()> {
        let event = StationFeedbackEvent {
            item_type: Some(feedback_type.to_string()),
            timestamp: Utc::now(),
            from: None,
            track_id,
            total_played,
            track_length: None,
        };
        let feedback = StationFeedback {
            batch_id,
            event,
            from,
        };

        let opts = SendStationFeedbackOptions::new(station_id, feedback);
        self.client.send_station_feedback(&opts).await?;

        Ok(())
    }

    pub async fn toggle_like_track(&self, track_id: String, is_liked: bool) -> Result<()> {
        if is_liked {
            let opts = RemoveLikedTracksOptions::new(self.user_id, vec![track_id]);
            self.client.remove_liked_tracks(&opts).await?;
        } else {
            let opts = AddLikedTracksOptions::new(self.user_id, vec![track_id]);
            self.client.add_liked_tracks(&opts).await?;
        }

        Ok(())
    }

    pub async fn add_like_track(&self, track_id: String) -> Result<()> {
        let opts = AddLikedTracksOptions::new(self.user_id, vec![track_id]);
        self.client.add_liked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_track(&self, track_id: String) -> Result<()> {
        let opts = RemoveLikedTracksOptions::new(self.user_id, vec![track_id]);
        self.client.remove_liked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn toggle_dislike_track(&self, track_id: String, is_disliked: bool) -> Result<()> {
        if is_disliked {
            let opts = RemoveDislikedTracksOptions::new(self.user_id, vec![track_id]);
            self.client.remove_disliked_tracks(&opts).await?;
        } else {
            let opts = AddDislikedTracksOptions::new(self.user_id, vec![track_id]);
            self.client.add_disliked_tracks(&opts).await?;
        }

        Ok(())
    }

    pub async fn add_dislike_track(&self, track_id: String) -> Result<()> {
        let opts = AddDislikedTracksOptions::new(self.user_id, vec![track_id]);
        self.client.add_disliked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn remove_dislike_track(&self, track_id: String) -> Result<()> {
        let opts = RemoveDislikedTracksOptions::new(self.user_id, vec![track_id]);
        self.client.remove_disliked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn add_like_album(&self, album_id: u32) -> Result<()> {
        let opts = AddLikedAlbumOptions::new(self.user_id, album_id);
        self.client.add_liked_album(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_album(&self, album_id: u32) -> Result<()> {
        let opts = RemoveLikedAlbumOptions::new(self.user_id, album_id);
        self.client.remove_liked_album(&opts).await?;
        Ok(())
    }

    pub async fn add_like_playlist(&self, owner_uid: u64, kind: u32) -> Result<()> {
        let opts = AddLikedPlaylistOptions::new(self.user_id, owner_uid, kind);
        self.client.add_liked_playlist(&opts).await?;
        Ok(())
    }

    pub async fn add_track_to_playlist(
        &self,
        kind: u32,
        track_id: String,
        album_id: String,
    ) -> Result<()> {
        let playlist = self.fetch_playlist_bare(kind).await?;
        let revision = playlist.revision;

        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        let diff = Diff::new(DiffOp::insert(0), vec![track]);
        let opts = ModifyPlaylistOptions::new(self.user_id, kind, diff, revision);
        self.client.modify_playlist(&opts).await?;
        Ok(())
    }

    pub async fn remove_track_from_playlist(
        &self,
        kind: u32,
        track_id: String,
        album_id: String,
    ) -> Result<()> {
        let playlist = self.fetch_playlist_bare(kind).await?;
        let revision = playlist.revision;

        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        let diff = Diff::new(DiffOp::delete(0, 1), vec![track]);
        let opts = ModifyPlaylistOptions::new(self.user_id, kind, diff, revision);
        self.client.modify_playlist(&opts).await?;
        Ok(())
    }

    pub async fn move_track_in_playlist(
        &self,
        kind: u32,
        from_index: usize,
        to_index: usize,
        track_id: String,
        album_id: String,
    ) -> Result<()> {
        let playlist = self.fetch_playlist_bare(kind).await?;
        let revision = playlist.revision;

        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        // In Yandex Music, moving a track is done by deleting it from the old position and inserting it into the new one
        let diff_delete = Diff::new(
            DiffOp::delete(from_index, from_index + 1),
            vec![track.clone()],
        );
        let diff_insert = Diff::new(DiffOp::insert(to_index), vec![track]);

        let opts1 = ModifyPlaylistOptions::new(self.user_id, kind, diff_delete, revision);
        self.client.modify_playlist(&opts1).await?;

        // Get the updated revision after the first step
        let playlist_updated = self.fetch_playlist_bare(kind).await?;
        let opts2 =
            ModifyPlaylistOptions::new(self.user_id, kind, diff_insert, playlist_updated.revision);
        self.client.modify_playlist(&opts2).await?;

        Ok(())
    }

    pub async fn create_playlist(&self, title: String, is_public: bool) -> Result<()> {
        let visibility = if is_public { "public" } else { "private" };
        let opts = CreatePlaylistOptions::new(self.user_id, title, visibility);
        self.client.create_playlist(&opts).await?;
        Ok(())
    }

    pub async fn delete_playlist(&self, kind: u32) -> Result<()> {
        let opts = DeletePlaylistOptions::new(self.user_id, kind);
        self.client.delete_playlist(&opts).await?;
        Ok(())
    }

    pub async fn rename_playlist(&self, kind: u32, new_title: String) -> Result<()> {
        let opts = RenamePlaylistOptions::new(self.user_id, kind, new_title);
        self.client.rename_playlist(&opts).await?;
        Ok(())
    }

    pub async fn change_playlist_visibility(&self, kind: u32, is_public: bool) -> Result<()> {
        let visibility = if is_public { "public" } else { "private" };
        let opts = ChangePlaylistVisibilityOptions::new(self.user_id, kind, visibility);
        self.client.change_playlist_visibility(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_playlist(&self, owner_uid: u64, kind: u32) -> Result<()> {
        let opts = RemoveLikedPlaylistOptions::new(self.user_id, owner_uid, kind);
        self.client.remove_liked_playlist(&opts).await?;
        Ok(())
    }

    pub async fn add_like_artist(&self, artist_id: String) -> Result<()> {
        let opts = AddLikedArtistOptions::new(self.user_id, artist_id);
        self.client.add_liked_artist(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_artist(&self, artist_id: String) -> Result<()> {
        let opts = RemoveLikedArtistOptions::new(self.user_id, artist_id);
        self.client.remove_liked_artist(&opts).await?;
        Ok(())
    }

    pub async fn add_dislike_artist(&self, artist_id: String) -> Result<()> {
        let opts = AddDislikedArtistOptions::new(self.user_id, artist_id);
        self.client.add_disliked_artist(&opts).await?;
        Ok(())
    }

    pub async fn remove_dislike_artist(&self, artist_id: String) -> Result<()> {
        let opts = RemoveDislikedArtistOptions::new(self.user_id, artist_id);
        self.client.remove_disliked_artist(&opts).await?;
        Ok(())
    }

    pub async fn get_account_info(&self) -> Result<crate::api::models::UserAccountDto> {
        let status = self.client.get_account_status().await?;

        let mut avatar_url = None;
        if let Ok(resp) = self
            .client
            .inner
            .get("https://api.music.yandex.net/account/about")
            .send()
            .await
            && let Ok(json) = resp.json::<serde_json::Value>().await
            && let Some(id) = json["result"]["avatarId"].as_str()
        {
            avatar_url = Some(format!(
                "https://avatars.mds.yandex.net/get-yapic/{}/islands-200",
                id
            ));
        }

        Ok(crate::api::models::UserAccountDto::from_yandex(
            status, avatar_url,
        ))
    }

    pub async fn fetch_liked_ids(&self) -> Result<Vec<String>> {
        let opts =
            yandex_music::api::track::get_liked_tracks::GetLikedTracksOptions::new(self.user_id);
        let library = self.client.get_liked_tracks(&opts).await?;

        Ok(library.tracks.into_iter().map(|t| t.id).collect())
    }

    pub async fn fetch_liked_collection(&self, revision: Option<u64>) -> Result<Collection> {
        let get_opt = || {
            let mut opt = CollectionSyncOption::new();
            if let Some(rev) = revision {
                opt = opt.revision(rev);
            }
            opt
        };
        let opts = CollectionSyncOptions::new()
            .liked_tracks(get_opt())
            .liked_albums(get_opt())
            .liked_artists(get_opt())
            .liked_playlists(get_opt());
        Ok(self.client.collection_sync(&opts).await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extracts_wrapped_albums_from_top_level_array() {
        let body = json!([
            {
                "timestamp": "2026-05-26T00:00:00+00:00",
                "album": {
                    "id": 10,
                    "title": "Album title"
                }
            }
        ]);

        let albums: Vec<Album> = ApiService::extract_liked(&body, "albums", "album");

        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].id, Some(10));
        assert_eq!(albums[0].title.as_deref(), Some("Album title"));
    }

    #[test]
    fn extracts_direct_artists_from_top_level_array() {
        let body = json!([
            {
                "id": "20",
                "name": "Artist name"
            }
        ]);

        let artists: Vec<Artist> = ApiService::extract_liked(&body, "artists", "artist");

        assert_eq!(artists.len(), 1);
        assert_eq!(artists[0].id.as_deref(), Some("20"));
        assert_eq!(artists[0].name.as_deref(), Some("Artist name"));
    }

    #[test]
    fn extracts_direct_albums_from_library_shape() {
        let body = json!({
            "result": {
                "library": {
                    "albums": [
                        {
                            "id": 30,
                            "title": "Library album"
                        }
                    ]
                }
            }
        });

        let albums: Vec<Album> = ApiService::extract_liked(&body, "albums", "album");

        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].id, Some(30));
        assert_eq!(albums[0].title.as_deref(), Some("Library album"));
    }
}
