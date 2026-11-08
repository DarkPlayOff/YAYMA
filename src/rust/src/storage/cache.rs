use crate::db::AppDatabase;
use crate::util::tls::USER_AGENT;
use directories::ProjectDirs;
use foldhash::HashMap;
use foldhash::HashMapExt;
use foldhash::fast::FixedState;
use parking_lot::Mutex as SyncMutex;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::OnceLock;
use tokio::fs;
use tokio::sync::Mutex;
use tokio::sync::broadcast;

/// How long a follower waits for the download it joined, and how long the
/// downloader itself may run. The follower's budget is longer on purpose: it
/// also has to cover the downloader's own timeout.
const DOWNLOAD_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);
const DOWNLOAD_WAIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(90);

/// Waits for the in-flight download of a URL.
///
/// Three failures can happen at once here — the downloader timed out, the
/// broadcast channel died, or the payload says the download failed — so each
/// `?` turns one layer into a flat error instead of nesting matches.
async fn await_download(
    rx: &mut broadcast::Receiver<Result<PathBuf, String>>,
) -> Result<PathBuf, Box<dyn std::error::Error + Send + Sync>> {
    let received = tokio::time::timeout(DOWNLOAD_WAIT_TIMEOUT, rx.recv())
        .await
        .map_err(|_| "timed out waiting for the http cache download")?;
    let outcome = received.map_err(|e| format!("http cache download channel closed: {e}"))?;
    outcome.map_err(Into::into)
}

/// Streams the body into `path`, returning the bytes actually written.
///
/// The byte count is what landed on disk, not `Content-Length` (which counts
/// the untouched body and ignores any transfer decoding), so the cache quota
/// matches the files. A chunk or write error fails the download: treating it
/// as EOF would cache a truncated file as valid forever.
async fn write_chunks(
    mut response: reqwest::Response,
    path: &Path,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    use tokio::io::AsyncWriteExt;

    let mut file = fs::File::create(path).await?;
    let mut written = 0u64;
    while let Some(chunk) =
        tokio::time::timeout(std::time::Duration::from_secs(30), response.chunk())
            .await
            .map_err(|_| "http cache chunk timed out")?
            .map_err(|e| format!("http cache chunk failed: {e}"))?
    {
        file.write_all(&chunk).await?;
        written += chunk.len() as u64;
    }
    file.flush().await?;
    Ok(written)
}

/// Content-addressed file name for a URL. Shared by both caches so a cover and
/// a track for the same URL can't end up in differently named files.
fn hash_url(url: &str) -> String {
    let mut s = FixedState::with_seed(0).build_hasher();
    s.write(url.as_bytes());
    format!("{:x}", s.finish())
}

pub struct ActiveDownloads {
    pub map: SyncMutex<HashMap<String, broadcast::Sender<Result<PathBuf, String>>>>,
}

pub static ACTIVE_DOWNLOADS: OnceLock<ActiveDownloads> = OnceLock::new();

fn get_active_downloads() -> &'static ActiveDownloads {
    ACTIVE_DOWNLOADS.get_or_init(|| ActiveDownloads {
        map: SyncMutex::new(HashMap::new()),
    })
}

/// Removes the in-flight entry when dropped. Without it, cancelling the
/// downloader's future (task abort) left its sender in the static map and
/// every later `get_file` for that URL waited on a channel nobody would use.
struct DownloadGuard(String);

impl Drop for DownloadGuard {
    fn drop(&mut self) {
        get_active_downloads().map.lock().remove(&self.0);
    }
}

pub struct HttpCache {
    cache_dir: PathBuf,
    client: reqwest::Client,
    db: Arc<Mutex<AppDatabase>>,
}

impl HttpCache {
    pub fn new(db: Arc<Mutex<AppDatabase>>, base_path: Option<PathBuf>) -> Self {
        let cache_dir = if let Some(path) = base_path {
            path.join("http_cache")
        } else if let Some(proj_dirs) = ProjectDirs::from("com", "yamusic", "yamusic") {
            proj_dirs.cache_dir().join("http_cache")
        } else {
            std::env::current_dir()
                .unwrap_or_default()
                .join("cache")
                .join("http_cache")
        };

        let client = match crate::util::tls::builder()
            .user_agent(USER_AGENT)
            .pool_max_idle_per_host(5)
            .timeout(std::time::Duration::from_secs(30))
            .build()
        {
            Ok(client) => client,
            Err(e) => {
                // Same reasoning as the stream client: the custom builder
                // carries the platform verifier, so losing it must be logged.
                tracing::error!(error = %e, "http_cache_client_build_failed_using_default");
                reqwest::Client::new()
            }
        };

        Self {
            cache_dir,
            client,
            db,
        }
    }

    pub fn get_cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    pub async fn get_file(
        &self,
        url: &str,
    ) -> Result<PathBuf, Box<dyn std::error::Error + Send + Sync>> {
        // 1. Check DB for existing cache
        {
            let path_opt = {
                let mut db = self.db.lock().await;
                db.get_cache_metadata(url).await.ok().flatten()
            };

            if let Some(entry) = path_opt {
                let path = PathBuf::from(&entry.path);
                if path.exists() && !entry.expired {
                    return Ok(path);
                }
                // Expired or missing file — will re-download below
            }
        }

        // 2. Deduplication: check if already downloading
        let (tx, mut rx) = {
            let mut active = get_active_downloads().map.lock();
            if let Some(tx) = active.get(url) {
                (None, tx.subscribe())
            } else {
                let (tx, _rx) = broadcast::channel::<Result<PathBuf, String>>(16);
                active.insert(url.to_string(), tx.clone());
                let rx = tx.subscribe();
                (Some(tx), rx)
            }
        };

        if let Some(tx) = tx {
            // We are the downloader. The guard removes the map entry on every
            // exit path, including cancellation of this future.
            let guard = DownloadGuard(url.to_string());
            let result = tokio::time::timeout(DOWNLOAD_TIMEOUT, self.perform_download(url))
                .await
                .map_err(|_| {
                    Box::<dyn std::error::Error + Send + Sync>::from(
                        "http cache download timed out",
                    )
                })
                .and_then(|r| r);

            // Remove before send: a waiter subscribing between send and remove
            // would wait on an already-fired broadcast channel forever.
            drop(guard);

            // Broadcast the result to all waiters
            let broadcast_result = result
                .as_ref()
                .map(|p| p.clone())
                .map_err(|e| e.to_string());

            let _ = tx.send(broadcast_result);

            result
        } else {
            await_download(&mut rx).await
        }
    }

    async fn perform_download(
        &self,
        url: &str,
    ) -> Result<PathBuf, Box<dyn std::error::Error + Send + Sync>> {
        let filename = hash_url(url);

        let path_only = url.split('?').next().unwrap_or(url);
        let last_segment = path_only.rsplit('/').next().unwrap_or("");
        let extension = if last_segment.contains('.') {
            last_segment.rsplit('.').next().unwrap_or("bin")
        } else {
            "bin"
        };

        let file_path = self.cache_dir.join(format!("{}.{}", filename, extension));
        let part_path = self
            .cache_dir
            .join(format!("{}.{}.part", filename, extension));

        fs::create_dir_all(&self.cache_dir).await?;

        let response = self
            .client
            .get(url)
            .header("Referer", "https://music.yandex.ru/")
            .send()
            .await?;

        if !response.status().is_success() {
            let err_msg = format!("HTTP error {}: for URL {}", response.status(), url);
            return Err(err_msg.into());
        }

        let etag = response
            .headers()
            .get("etag")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());

        // Write to `.part`, then rename: a cancelled or failed download must
        // never be left behind as a complete-looking cache entry.
        let size = match write_chunks(response, &part_path).await {
            Ok(written) => written,
            Err(e) => {
                let _ = fs::remove_file(&part_path).await;
                return Err(e);
            }
        };
        fs::rename(&part_path, &file_path).await?;

        // Update DB
        {
            let path_str = file_path.to_string_lossy().into_owned();
            let mut db = self.db.lock().await;
            let _ = db
                .update_cache_metadata(url, &path_str, size, etag.as_deref())
                .await;
        }

        Ok(file_path)
    }

    pub async fn prune(
        &self,
        max_size_bytes: i64,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let to_delete = {
            let mut db = self.db.lock().await;
            db.prune_cache(max_size_bytes).await?
        };

        for path_str in to_delete {
            let _ = fs::remove_file(path_str).await;
        }

        Ok(())
    }

    pub async fn get_size(&self) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
        if !self.cache_dir.exists() {
            return Ok(0);
        }

        let mut total_size = 0;
        let mut dir = fs::read_dir(&self.cache_dir).await?;
        while let Some(entry) = dir.next_entry().await? {
            if let Ok(metadata) = entry.metadata().await
                && metadata.is_file()
            {
                total_size += metadata.len() as i64;
            }
        }
        Ok(total_size)
    }

    pub async fn clear(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if self.cache_dir.exists() {
            fs::remove_dir_all(&self.cache_dir).await?;
        }
        let mut db = self.db.lock().await;
        let _ = db.clear_cache_metadata().await;
        Ok(())
    }

    /// Prune all expired entries from cache.
    pub async fn prune_expired(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let to_delete = {
            let mut db = self.db.lock().await;
            db.prune_expired().await?
        };

        for path_str in to_delete {
            let _ = fs::remove_file(path_str).await;
        }

        Ok(())
    }
}

pub struct TrackCache {
    cache_dir: PathBuf,
}

/// Single source of truth for offline track extensions.
/// `m4a` files carry AAC codec — mapping lives here only.
pub const SUPPORTED_TRACK_EXTS: &[(&str, &str)] =
    &[("flac", "flac"), ("m4a", "aac"), ("mp3", "mp3")];

impl TrackCache {
    pub fn new(base_path: Option<PathBuf>) -> Self {
        let cache_dir = if let Some(path) = base_path {
            path.join("offline_tracks")
        } else if let Some(proj_dirs) = ProjectDirs::from("com", "yamusic", "yamusic") {
            proj_dirs.data_dir().join("offline_tracks")
        } else {
            std::env::current_dir()
                .unwrap_or_default()
                .join("data")
                .join("offline_tracks")
        };

        Self { cache_dir }
    }

    pub fn get_cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    pub async fn save_cover(&self, url: &str, source_path: &Path) -> Result<(), std::io::Error> {
        let covers_dir = self.cache_dir.join("covers");
        fs::create_dir_all(&covers_dir).await?;
        let filename = hash_url(url);
        let dest_path = covers_dir.join(format!("{}.jpg", filename));
        if !dest_path.exists() {
            fs::copy(source_path, dest_path).await?;
        }
        Ok(())
    }

    pub async fn get_cover(&self, url: &str) -> Option<PathBuf> {
        let covers_dir = self.cache_dir.join("covers");
        let filename = hash_url(url);
        let dest_path = covers_dir.join(format!("{}.jpg", filename));
        if dest_path.exists() {
            Some(dest_path)
        } else {
            None
        }
    }

    pub fn get_track_file(&self, track_id: &str) -> Option<(PathBuf, String)> {
        // Try to find the file with any supported extension.
        // Skips empty/corrupt downloads, matching `get_all_track_ids`.
        for (ext, codec) in SUPPORTED_TRACK_EXTS {
            let path = self.cache_dir.join(format!("{}.{}", track_id, ext));
            if path.exists()
                && let Ok(meta) = std::fs::metadata(&path)
                && meta.len() > 0
            {
                return Some((path, codec.to_string()));
            }
        }
        None
    }

    pub async fn init(&self) -> Result<(), std::io::Error> {
        fs::create_dir_all(&self.cache_dir).await
    }

    pub async fn get_all_track_ids(&self) -> Vec<String> {
        let mut ids = Vec::new();
        if !self.cache_dir.exists() {
            return ids;
        }

        if let Ok(mut entries) = fs::read_dir(&self.cache_dir).await {
            while let Ok(Some(entry)) = entries.next_entry().await {
                let Ok(metadata) = entry.metadata().await else {
                    continue;
                };
                if !metadata.is_file() || metadata.len() == 0 {
                    continue;
                }
                let path = entry.path();
                // Only real downloads count. `123.flac.part` (extension
                // "part") and the legacy `.aac` files are not playable, and
                // listing them showed phantom entries in the downloads view.
                let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
                    continue;
                };
                if !SUPPORTED_TRACK_EXTS.iter().any(|(known, _)| *known == ext) {
                    continue;
                }
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    ids.push(stem.to_string());
                }
            }
        }
        ids
    }

    pub async fn get_size(&self) -> Result<i64, std::io::Error> {
        let mut size = 0;
        if self.cache_dir.exists() {
            // Include tracks
            let mut entries = fs::read_dir(&self.cache_dir).await?;
            while let Ok(Some(entry)) = entries.next_entry().await {
                if let Ok(metadata) = entry.metadata().await
                    && metadata.is_file()
                {
                    size += metadata.len() as i64;
                }
            }
            // Include covers
            let covers_dir = self.cache_dir.join("covers");
            if covers_dir.exists() {
                let mut covers = fs::read_dir(&covers_dir).await?;
                while let Ok(Some(entry)) = covers.next_entry().await {
                    if let Ok(metadata) = entry.metadata().await
                        && metadata.is_file()
                    {
                        size += metadata.len() as i64;
                    }
                }
            }
        }
        Ok(size)
    }

    pub async fn clear(&self) -> Result<(), std::io::Error> {
        if self.cache_dir.exists() {
            let _ = fs::remove_dir_all(&self.cache_dir).await;
            let _ = fs::create_dir_all(&self.cache_dir).await;
        }
        Ok(())
    }

    pub async fn delete_track(&self, track_id: &str) -> Result<(), std::io::Error> {
        // Delete the track file (final + stale partials)
        for (ext, _) in SUPPORTED_TRACK_EXTS {
            let path = self.cache_dir.join(format!("{}.{}", track_id, ext));
            if path.exists() {
                let _ = fs::remove_file(path).await;
            }
            let part = self.cache_dir.join(format!("{}.{}.part", track_id, ext));
            if part.exists() {
                let _ = fs::remove_file(part).await;
            }
        }
        // Legacy `.aac` files never matched get_track_file — clean them too.
        let legacy = self.cache_dir.join(format!("{}.aac", track_id));
        if legacy.exists() {
            let _ = fs::remove_file(legacy).await;
        }
        Ok(())
    }
}
