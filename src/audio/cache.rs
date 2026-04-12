use foldhash::HashMap;
use foldhash::HashMapExt;
use parking_lot::RwLock;
use std::sync::Arc;

#[derive(Clone, Default)]
pub struct UrlCache {
    cache: Arc<RwLock<HashMap<String, (String, String)>>>,
}

impl UrlCache {
    pub fn new() -> Self {
        Self {
            cache: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn get(&self, track_id: &str) -> Option<(String, String)> {
        self.cache.read().get(track_id).cloned()
    }

    pub fn insert(&self, track_id: String, url: String, codec: String) {
        self.cache.write().insert(track_id, (url, codec));
    }

    pub fn remove(&self, track_id: &str) {
        self.cache.write().remove(track_id);
    }
}
