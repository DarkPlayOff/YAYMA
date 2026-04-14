use crate::app::get_db;
use directories::ProjectDirs;
use foldhash::HashMap;
use foldhash::fast::FixedState;
use foldhash::HashMapExt;
use parking_lot::Mutex as SyncMutex;
use std::hash::{BuildHasher, Hasher};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tokio::fs;
use tokio::sync::broadcast;

pub struct ActiveDownloads {
    pub map: SyncMutex<HashMap<String, broadcast::Sender<Result<PathBuf, String>>>>,
}

pub static ACTIVE_DOWNLOADS: OnceLock<ActiveDownloads> = OnceLock::new();

fn get_active_downloads() -> &'static ActiveDownloads {
    ACTIVE_DOWNLOADS.get_or_init(|| ActiveDownloads {
        map: SyncMutex::new(HashMap::new()),
    })
}

pub struct HttpCache {
    cache_dir: PathBuf,
    client: reqwest::Client,
}

impl Default for HttpCache {
    fn default() -> Self {
        Self::new()
    }
}

impl HttpCache {
    pub fn new() -> Self {
        let cache_dir = if let Some(proj_dirs) = ProjectDirs::from("com", "yamusic", "yamusic") {
            proj_dirs.cache_dir().join("http_cache")
        } else {
            std::env::current_dir()
                .unwrap_or_default()
                .join("cache")
                .join("http_cache")
        };

        let client = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 YandexMusic/5.82.0")
            .pool_max_idle_per_host(5)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());

        Self { cache_dir, client }
    }

    pub fn get_cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    fn hash_url(&self, url: &str) -> String {
        let mut s = FixedState::with_seed(0).build_hasher();
        s.write(url.as_bytes());
        format!("{:x}", s.finish())
    }

    pub async fn get_file(
        &self,
        url: &str,
    ) -> Result<PathBuf, Box<dyn std::error::Error + Send + Sync>> {
        // 1. Check DB for existing cache
        {
            if let Some(db_arc) = get_db() {
                let path_opt = tokio::task::block_in_place(|| {
                    let db = db_arc.lock();
                    db.get_cache_metadata(url).ok().flatten()
                });

                if let Some((path, _, is_expired)) = path_opt {
                    let path = PathBuf::from(&path);
                    if path.exists() && !is_expired {
                        return Ok(path);
                    }
                    // Expired or missing file — will re-download below
                }
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
            // We are the downloader
            let result = self.perform_download(url).await;

            // Broadcast the result to all waiters
            let broadcast_result = result
                .as_ref()
                .map(|p| p.clone())
                .map_err(|e| e.to_string());

            let _ = tx.send(broadcast_result);
            get_active_downloads().map.lock().remove(url);

            result
        } else {
            // Wait for existing download
            match rx.recv().await? {
                Ok(path) => Ok(path),
                Err(e) => Err(e.into()),
            }
        }
    }

    async fn perform_download(
        &self,
        url: &str,
    ) -> Result<PathBuf, Box<dyn std::error::Error + Send + Sync>> {
        let filename = self.hash_url(url);

        let path_only = url.split('?').next().unwrap_or(url);
        let last_segment = path_only.rsplit('/').next().unwrap_or("");
        let extension = if last_segment.contains('.') {
            last_segment.rsplit('.').next().unwrap_or("bin")
        } else {
            "bin"
        };

        let file_path = self.cache_dir.join(format!("{}.{}", filename, extension));

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

        let size = response.content_length().unwrap_or(0);

        // Stream the response to file to avoid loading everything into RAM
        let mut file = fs::File::create(&file_path).await?;
        let mut response = response;
        while let Ok(Some(chunk)) = response.chunk().await {
            tokio::io::AsyncWriteExt::write_all(&mut file, &chunk).await?;
        }
        tokio::io::AsyncWriteExt::flush(&mut file).await?;

        // Update DB
        if let Some(db_arc) = get_db() {
            let path_str = file_path.to_string_lossy().to_string();
            tokio::task::block_in_place(|| {
                let db = db_arc.lock();
                let _ = db.update_cache_metadata(url, &path_str, size, etag.as_deref());
            });
        }

        Ok(file_path)
    }

    pub async fn prune(
        &self,
        max_size_bytes: i64,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let to_delete = {
            let Some(db_arc) = get_db() else {
                return Ok(()); // DB not initialized
            };
            tokio::task::block_in_place(|| {
                let db = db_arc.lock();
                db.prune_cache(max_size_bytes)
            })?
        };

        for path_str in to_delete {
            let _ = fs::remove_file(path_str).await;
        }

        Ok(())
    }

    pub async fn clear(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        if self.cache_dir.exists() {
            fs::remove_dir_all(&self.cache_dir).await?;
        }
        Ok(())
    }

    /// Prune all expired entries from cache.
    pub async fn prune_expired(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let to_delete = {
            let Some(db_arc) = get_db() else {
                return Ok(()); // DB not initialized, nothing to prune
            };
            tokio::task::block_in_place(|| {
                let db = db_arc.lock();
                db.prune_expired()
            })?
        };

        for path_str in to_delete {
            let _ = fs::remove_file(path_str).await;
        }

        Ok(())
    }
}

pub static HTTP_CACHE: tokio::sync::OnceCell<HttpCache> = tokio::sync::OnceCell::const_new();

pub async fn get_http_cache() -> &'static HttpCache {
    HTTP_CACHE.get_or_init(|| async { HttpCache::new() }).await
}
