//! Ported from `yandex_music::api::track::{get_file_info, get_file_info_batch}`.
//!
//! The crate's internal request plumbing (`YandexMusicClient::request`,
//! `Endpoint`, `JoinDisplay`, ...) is `pub(crate)`-scoped and not reachable
//! from here, so the HTTP call and signing are reimplemented locally instead
//! of just calling into the crate. The only intentional deviation from the
//! upstream implementation is `#[serde(default)]` on `TrackFileInfo::size`:
//! Yandex's API sometimes omits `size` from the response, which otherwise
//! fails deserialization for every track.

use std::fmt::Display;

use serde::Deserialize;
use yandex_music::{
    api::{utils::create_file_info_sign, Response},
    error::{ClientError, YandexMusicError},
    model::info::file_info::{Codec, Quality},
    YandexMusicClient, API_PATH,
};

pub use yandex_music::model::info::file_info::{Codec as FileInfoCodec, Quality as FileInfoQuality};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackFileInfo {
    pub bitrate: u32,
    pub codec: String,
    pub gain: bool,
    pub quality: String,
    pub real_id: String,
    #[serde(default)]
    pub size: u64,
    pub track_id: String,
    pub transport: String,
    pub url: String,
    pub urls: Vec<String>,
}

fn delimited<T: Display>(items: &[T], delimiter: &str) -> String {
    items
        .iter()
        .map(|item| item.to_string())
        .collect::<Vec<_>>()
        .join(delimiter)
}

fn concatenated<T: Display>(items: &[T]) -> String {
    items.iter().map(|item| item.to_string()).collect()
}

fn build_query(path: &str, params: &[(&str, &str)]) -> String {
    let query = params
        .iter()
        .map(|(k, v)| format!("{}={}", k, urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    format!("{}?{}", path, query)
}

pub struct GetFileInfoOptions {
    pub track_id: String,
    pub quality: Quality,
    pub codecs: Vec<Codec>,
    pub is_encrypted: bool,
}

impl GetFileInfoOptions {
    pub fn new(track_id: impl Into<String>) -> Self {
        Self {
            track_id: track_id.into(),
            quality: Quality::Lossless,
            codecs: Codec::all().to_vec(),
            is_encrypted: false,
        }
    }

    pub fn quality(mut self, quality: Quality) -> Self {
        self.quality = quality;
        self
    }

    pub fn codecs<I>(mut self, codecs: I) -> Self
    where
        I: IntoIterator<Item = Codec>,
    {
        self.codecs = codecs.into_iter().collect();
        self
    }

    pub fn is_encrypted(mut self, is_encrypted: bool) -> Self {
        self.is_encrypted = is_encrypted;
        self
    }

    fn path(&self) -> String {
        let transport = if self.is_encrypted { "encraw" } else { "raw" };

        let quality = self.quality.to_string();
        let (ts, sign) = create_file_info_sign(
            &self.track_id,
            &quality,
            &concatenated(&self.codecs),
            transport,
        );

        build_query(
            "get-file-info",
            &[
                ("ts", &ts),
                ("trackId", &self.track_id),
                ("quality", &quality),
                ("codecs", &delimited(&self.codecs, ",")),
                ("transports", transport),
                ("sign", &sign),
            ],
        )
    }
}

pub struct GetFileInfoBatchOptions {
    pub track_ids: Vec<String>,
    pub quality: Quality,
    pub codecs: Vec<Codec>,
    pub is_encrypted: bool,
}

impl GetFileInfoBatchOptions {
    pub fn new<I, S>(track_ids: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            track_ids: track_ids.into_iter().map(Into::into).collect(),
            quality: Quality::Lossless,
            codecs: Codec::all().to_vec(),
            is_encrypted: false,
        }
    }

    pub fn quality(mut self, quality: Quality) -> Self {
        self.quality = quality;
        self
    }

    pub fn codecs<I>(mut self, codecs: I) -> Self
    where
        I: IntoIterator<Item = Codec>,
    {
        self.codecs = codecs.into_iter().collect();
        self
    }

    pub fn is_encrypted(mut self, is_encrypted: bool) -> Self {
        self.is_encrypted = is_encrypted;
        self
    }

    fn path(&self) -> String {
        let transport = if self.is_encrypted { "encraw" } else { "raw" };

        let quality = self.quality.to_string();
        let (ts, sign) = yandex_music::api::utils::create_file_info_batch_sign(
            &self.track_ids,
            &quality,
            &concatenated(&self.codecs),
            transport,
        );

        build_query(
            "get-file-info/batch",
            &[
                ("ts", &ts),
                ("trackIds", &delimited(&self.track_ids, ",")),
                ("quality", &quality),
                ("codecs", &delimited(&self.codecs, ",")),
                ("transports", transport),
                ("sign", &sign),
            ],
        )
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GetFileInfoResult {
    download_info: TrackFileInfo,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GetFileInfoBatchResult {
    download_infos: Vec<TrackFileInfo>,
}

async fn send_get<T: for<'de> Deserialize<'de>>(
    client: &YandexMusicClient,
    path: &str,
) -> Result<T, ClientError> {
    let url = format!("{}{}", API_PATH, path);
    // get-file-info validates the HMAC sign against a specific declared
    // client identity; the desktop identity used as the default header
    // elsewhere in this app is rejected (403) for this endpoint, so it's
    // overridden here to the Android identity known to be accepted.
    let response = client
        .inner
        .get(url)
        .header("X-Yandex-Music-Client", "YandexMusicAndroid/24024312")
        .send()
        .await?;
    let status_code = response.status();

    if !status_code.is_success() {
        if let Ok(res) = response.json::<Response>().await {
            if let Some(err) = res.error {
                return Err(err.into());
            }
        }

        return Err(ClientError::YandexMusicError {
            error: YandexMusicError {
                name: "RequestFailed".to_string(),
                message: Some(format!("Request failed with status code: {status_code}")),
            },
        });
    }

    let response: Response = response.json().await?;

    if let Some(error) = response.error {
        return Err(error.into());
    }

    let result = response
        .result
        .ok_or_else(|| ClientError::YandexMusicError {
            error: YandexMusicError {
                name: "MissingResult".to_string(),
                message: Some("API response contains no result".to_string()),
            },
        })?;

    Ok(serde_json::from_value(result)?)
}

/// Get track file info (direct links) with support for high quality/lossless.
pub async fn get_file_info(
    client: &YandexMusicClient,
    options: &GetFileInfoOptions,
) -> Result<TrackFileInfo, ClientError> {
    let result: GetFileInfoResult = send_get(client, &options.path()).await?;
    Ok(result.download_info)
}

/// Get multiple track file infos (direct links) with support for high quality/lossless.
pub async fn get_file_info_batch(
    client: &YandexMusicClient,
    options: &GetFileInfoBatchOptions,
) -> Result<Vec<TrackFileInfo>, ClientError> {
    let result: GetFileInfoBatchResult = send_get(client, &options.path()).await?;
    Ok(result.download_infos)
}
