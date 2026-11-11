use crate::api::models::AudioQuality;
use parking_lot::RwLock;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;
use tokio::time::sleep;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

use reqwest::header::{AUTHORIZATION, HeaderMap, HeaderValue};
use yandex_music::{DEFAULT_CLIENT_ID, YandexMusicClient, model::rotor::session::Session};

mod auth;
mod history;
mod library;
mod likes;
mod playlists;
mod plays;
mod rotor;
mod streaming;
mod uploads;

// `get-file-info`/`get-file-info/batch` sit directly on the playback critical path (called from
// StreamManager::create_stream_session before any audio can start), and the 15s buffering
// watchdog in AudioController silently pauses playback if that path stalls. Without its own
// timeout this request could otherwise hang far longer than 15s, so it errors out well before
// the watchdog would kick in, giving a real `Event::Error` instead of an unexplained pause.
const FILE_INFO_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_REQUEST_ATTEMPTS: usize = 3;
/// Legacy API host. `yandex_music::API_PATH` points at the `.net` host, but
/// these endpoints only exist on `.ru`.
const API_RU: &str = "https://api.music.yandex.ru";
const API_NET: &str = "https://api.music.yandex.net";

fn retryable_status(status: reqwest::StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 429 | 500..=504)
}

/// Transient failures only. Repeating a 404, a rejected request or a JSON
/// parse error just adds backoff to a path that is already waiting for audio.
fn retryable_client_error(error: &yandex_music::error::ClientError) -> bool {
    match error {
        // No status means the request never got an answer (DNS, TLS, timeout).
        yandex_music::error::ClientError::RequestError { error } => {
            error.status().is_none_or(retryable_status)
        }
        _ => false,
    }
}

/// Runs one crate call with the shared bounded backoff.
async fn retry_client_call<T, Fut>(mut call: impl FnMut() -> Fut) -> Result<T>
where
    Fut: std::future::Future<Output = std::result::Result<T, yandex_music::error::ClientError>>,
{
    let mut last = None;
    for attempt in 0..MAX_REQUEST_ATTEMPTS {
        match call().await {
            Ok(value) => return Ok(value),
            Err(error) if retryable_client_error(&error) => last = Some(error),
            Err(error) => return Err(error.into()),
        }
        if attempt + 1 < MAX_REQUEST_ATTEMPTS {
            sleep(Duration::from_millis(200 * (1 << attempt))).await;
        }
    }
    Err(last.expect("attempts are non-empty").into())
}

/// Execute a raw request with the same bounded retry policy as the desktop client.
/// The reqwest client timeout provides cancellation of the in-flight operation.
pub async fn send_with_retry<F>(mut make_request: F) -> Result<reqwest::Response>
where
    F: FnMut() -> reqwest::RequestBuilder,
{
    let mut last_error: Option<Box<dyn std::error::Error + Send + Sync>> = None;
    for attempt in 0..MAX_REQUEST_ATTEMPTS {
        match make_request().send().await {
            Ok(response) if response.status().is_success() => return Ok(response),
            Ok(response) if retryable_status(response.status()) => {
                last_error = Some(format!("HTTP {}", response.status()).into());
            }
            Ok(response) => return Err(format!("HTTP {}", response.status()).into()),
            Err(error) => last_error = Some(error.into()),
        }
        if attempt + 1 < MAX_REQUEST_ATTEMPTS {
            sleep(Duration::from_millis(200 * (1 << attempt))).await;
        }
    }
    Err(last_error.unwrap_or_else(|| "request failed".into()))
}

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

/// Numeric id of a playlist track entry, which arrives either as
/// `{"id": 123, ...}` (id-only) or as a bare number.
fn track_entry_id(entry: &serde_json::Value) -> Option<String> {
    let id = entry.get("id").unwrap_or(entry);
    match id {
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::String(s) => Some(s.clone()),
        _ => None,
    }
}

/// "Меньше ИИ" from an `account/settings` body. A missing field is an error,
/// not `false`: treating it as off would silently drop the setting.
fn parse_ai_reduction(body: &serde_json::Value) -> Result<bool> {
    body["result"]["aiContentReductionEnabled"]
        .as_bool()
        .ok_or_else(|| "account settings has no aiContentReductionEnabled".into())
}

/// Kinds of the playlists in a `/playlists?richTracks=false` response that
/// contain [track_id]. Entries without a track list are skipped, not guessed.
fn containing_kinds(body: &serde_json::Value, track_id: &str) -> Vec<u32> {
    body["result"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|playlist| {
            let kind = playlist["kind"].as_u64()? as u32;
            let has_track = playlist["tracks"].as_array().is_some_and(|tracks| {
                tracks
                    .iter()
                    .any(|t| track_entry_id(t).as_deref() == Some(track_id))
            });
            has_track.then_some(kind)
        })
        .collect()
}

pub struct ApiService {
    pub client: Arc<YandexMusicClient>,
    /// Separate client for `get-file-info`/`get-file-info/batch`: the crate's
    /// bundled sign key is only valid for its own default client identity
    /// (`DEFAULT_CLIENT_ID`), which doesn't match the desktop identity `client`
    /// above uses for everything else — signing with one and identifying as
    /// the other gets the request rejected with 403.
    file_info_client: Arc<YandexMusicClient>,
    pub http_client: reqwest::Client,
    user_id: u64,
    pub quality: RwLock<AudioQuality>,
    /// "Меньше ИИ": ask the rotor for fewer AI-generated tracks. The official
    /// clients express this as the `X-Yandex-Music-AI-Content-Rate` header on
    /// session requests, not as a body field.
    ai_reduction: AtomicBool,
}

#[derive(Debug)]
pub enum LikedTracksSync {
    /// Server confirmed our stored revision (section has no `values`):
    /// nothing to apply, keep the cached snapshot unchanged.
    Unchanged,
    Changed {
        revision: u64,
        /// Base track ids (strings in the API payload, e.g. `"156189026"`).
        liked_track_ids: Vec<String>,
        disliked_track_ids: Vec<String>,
    },
}

#[derive(Clone, Debug)]
pub struct TrackStreamInfo {
    pub url: String,
    pub mirror_urls: Vec<String>,
    pub codec: String,
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
            HeaderValue::from_str("YandexMusicDesktopAppWindows/5.110.1")?,
        );
        headers.insert("Accept-Language", HeaderValue::from_str("ru")?);
        headers.insert("Accept", HeaderValue::from_str("*/*")?);
        // Deliberately NOT setting X-Yandex-Music-Without-Invocation-Info here:
        // it strips `invocationInfo`/`exec-duration-millis` from every
        // response, which breaks the crate's strict typed deserialization
        // for account/playlists/etc.
        headers.insert(
            "Origin",
            HeaderValue::from_str("music-application://desktop")?,
        );

        let http_client = crate::util::tls::builder()
            .user_agent(crate::util::tls::USER_AGENT)
            .default_headers(headers.clone())
            .brotli(true)
            // Keep playlist/context requests from blocking playback indefinitely.
            .timeout(FILE_INFO_REQUEST_TIMEOUT)
            .build()?;

        let client = Arc::new(YandexMusicClient::from_client(http_client.clone()));

        // Built via `custom_client` (with headers replicated by hand) instead of the plain
        // `YandexMusicClient::builder(token).build()`, purely to attach a request timeout —
        // `ClientBuilder` has no `.timeout()` of its own.
        let mut file_info_headers = HeaderMap::with_capacity(2);
        file_info_headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("OAuth {}", token))?,
        );
        file_info_headers.insert(
            "X-Yandex-Music-Client",
            HeaderValue::from_str(DEFAULT_CLIENT_ID)?,
        );
        let file_info_http_client = crate::util::tls::builder()
            .default_headers(file_info_headers)
            .timeout(FILE_INFO_REQUEST_TIMEOUT)
            .build()?;
        let file_info_client = Arc::new(
            YandexMusicClient::builder(token)
                .custom_client(file_info_http_client)
                .build()?,
        );

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
            file_info_client,
            http_client,
            user_id,
            quality,
            ai_reduction: AtomicBool::new(false),
        })
    }

    pub fn set_quality(&self, quality: AudioQuality) {
        *self.quality.write() = quality;
    }

    pub fn get_quality(&self) -> AudioQuality {
        *self.quality.read()
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn containing_kinds_finds_playlists_by_track_id() {
        // Shape of `/playlists?withTracks=true&richTracks=false`: tracks are
        // id-only entries, and a playlist without tracks must not match.
        let body = json!({"result": [
            {"kind": 1000, "tracks": [{"id": 42, "timestamp": "2026-01-01T00:00:00+00:00"}]},
            {"kind": 1001, "tracks": [{"id": "7"}, {"id": "42"}]},
            {"kind": 1002, "tracks": []},
            {"kind": 1003},
            {"kind": 1004, "tracks": [{"id": 421}]},
        ]});

        assert_eq!(containing_kinds(&body, "42"), [1000, 1001]);
        assert!(containing_kinds(&json!({"result": []}), "42").is_empty());
        assert!(containing_kinds(&json!({"error": "unauthorized"}), "42").is_empty());
    }

    #[test]
    fn ai_reduction_reads_the_account_flag_and_rejects_a_missing_one() {
        let body = json!({"result": {"uid": 1, "aiContentReductionEnabled": true}});
        assert!(parse_ai_reduction(&body).unwrap());

        let body = json!({"result": {"uid": 1, "aiContentReductionEnabled": false}});
        assert!(!parse_ai_reduction(&body).unwrap());

        // Old accounts may lack the field; that must be an error, not "off".
        assert!(parse_ai_reduction(&json!({"result": {"uid": 1}})).is_err());
        assert!(parse_ai_reduction(&json!({"error": "unauthorized"})).is_err());
    }
}
