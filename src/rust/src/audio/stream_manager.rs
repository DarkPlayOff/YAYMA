use crate::audio::cache::UrlCache;
use crate::audio::progress::TrackProgress;
use crate::http::ApiService;
use crate::storage::cache::TrackCache;
use crate::stream;
use foldhash::HashMap;
use foldhash::HashMapExt;
use parking_lot::Mutex;
use std::sync::Arc;

use yandex_music::model::track::Track;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub type PrewarmResult = (stream::StreamingSession, Arc<TrackProgress>, String);

#[derive(Clone)]
pub struct StreamManager {
    api: Arc<ApiService>,
    url_cache: UrlCache,
    track_cache: Arc<TrackCache>,
    prewarm_cache: Arc<Mutex<HashMap<String, PrewarmResult>>>,
    http_client: reqwest::Client,
}

impl StreamManager {
    pub fn new(api: Arc<ApiService>, url_cache: UrlCache, track_cache: Arc<TrackCache>) -> Self {
        let http_client = reqwest::Client::builder()
            .pool_max_idle_per_host(4)
            .pool_idle_timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("failed to create streaming http client");

        Self {
            api,
            url_cache,
            track_cache,
            prewarm_cache: Arc::new(Mutex::new(HashMap::new())),
            http_client,
        }
    }

    pub fn prewarm(&self, track: Track) {
        let id = track.id.clone();
        {
            let mut cache = self.prewarm_cache.lock();
            if cache.contains_key(&id) {
                return;
            }
            cache.clear();
        }

        let this = self.clone();
        tokio::spawn(async move {
            if let Ok(result) = this.create_stream_session(&track, None).await {
                this.prewarm_cache.lock().insert(track.id, result);
            }
        });
    }

    pub fn invalidate_track(&self, track_id: &str) {
        self.url_cache.remove(track_id);
        self.prewarm_cache.lock().remove(track_id);
    }

    pub async fn is_track_offline(&self, track_id: &str) -> bool {
        self.track_cache.get_track_file(track_id).await.is_some()
    }

    pub async fn create_stream_session(
        &self,
        track: &Track,
        buffering_signal: Option<crate::util::reactive::Signal<bool>>,
    ) -> Result<PrewarmResult> {
        {
            let mut cache = self.prewarm_cache.lock();
            if let Some(res) = cache.remove(&track.id) {
                return Ok(res);
            }
        }

        let progress = Arc::new(TrackProgress::new());

        let progress_clone = progress.clone();

        // 1. Check if track is fully downloaded in offline cache
        if let Some((path, codec)) = self.track_cache.get_track_file(&track.id).await {
            let codec_clone = codec.clone();

            // For a local file, we know the length immediately and we don't have to wait for buffering
            let file = std::fs::File::open(&path).map_err(|e| {
                Box::<dyn std::error::Error + Send + Sync>::from(format!(
                    "failed to open offline file: {}",
                    e
                ))
            })?;
            let total_bytes = file.metadata().map(|m| m.len()).unwrap_or(0);

            let session = tokio::task::spawn_blocking(move || {
                stream::create_streaming_session(file, total_bytes, codec_clone, progress_clone)
            })
            .await
            .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))??;

            return Ok((session, progress, codec));
        }

        // 2. Fallback to streaming
        let (url, codec) = if let Some((url, codec)) = self.url_cache.get(&track.id) {
            (url, codec)
        } else {
            let (url, codec) = self
                .api
                .fetch_track_url(track.id.clone())
                .await
                .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))?;
            self.url_cache
                .insert(track.id.clone(), url.clone(), codec.clone());
            (url, codec)
        };

        let codec_clone = codec.clone();

        let client = self.http_client.clone();
        let duration_ms = track.duration.map(|d| d.as_millis() as u64);
        let data_source = stream::StreamingDataSource::new(
            client,
            url,
            Arc::clone(&progress),
            buffering_signal,
            duration_ms,
        )
        .await
        .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))?;

        let total_bytes = data_source.total_bytes();
        let session = tokio::task::spawn_blocking(move || {
            stream::create_streaming_session(data_source, total_bytes, codec_clone, progress_clone)
        })
        .await
        .map_err(|e| Box::<dyn std::error::Error + Send + Sync>::from(e.to_string()))??;

        Ok((session, progress, codec))
    }
}
