use foldhash::HashMap;
use foldhash::HashMapExt;
use parking_lot::RwLock;
use std::sync::Arc;
use std::time::{Duration, Instant};

const STRM_URL_TTL: Duration = Duration::from_secs(45);

#[derive(Clone)]
struct CachedUrl {
    url: String,
    mirror_urls: Vec<String>,
    codec: String,
    fetched_at: Instant,
}

#[derive(Clone, Default)]
pub struct UrlCache {
    cache: Arc<RwLock<HashMap<String, CachedUrl>>>,
}

impl UrlCache {
    pub fn new() -> Self {
        Self {
            cache: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn get(&self, track_id: &str) -> Option<(String, Vec<String>, String)> {
        let entry = self.cache.read().get(track_id).cloned()?;
        if entry.fetched_at.elapsed() >= STRM_URL_TTL {
            return None;
        }
        Some((entry.url, entry.mirror_urls, entry.codec))
    }

    pub fn insert(&self, track_id: String, url: String, mirror_urls: Vec<String>, codec: String) {
        let mut cache = self.cache.write();
        // Sweep expired entries + cap size so a long session doesn't grow
        // one entry per played track forever.
        cache.retain(|_, e| e.fetched_at.elapsed() < STRM_URL_TTL);
        if cache.len() > 200 {
            if let Some(oldest) = cache
                .iter()
                .min_by_key(|(_, e)| e.fetched_at)
                .map(|(k, _)| k.clone())
            {
                cache.remove(&oldest);
            }
        }
        cache.insert(
            track_id,
            CachedUrl {
                url,
                mirror_urls,
                codec,
                fetched_at: Instant::now(),
            },
        );
    }

    pub fn remove(&self, track_id: &str) {
        self.cache.write().remove(track_id);
    }
}
