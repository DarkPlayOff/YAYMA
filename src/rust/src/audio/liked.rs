use crate::util::track::CleanId;
use foldhash::HashSet;

pub type LikedSnapshot = (HashSet<String>, HashSet<String>);
pub type OrderedLikedSnapshot = (Vec<String>, HashSet<String>);

#[derive(Debug, Clone, Default)]
pub struct LikedCache {
    pub revision: Option<u64>,
    liked_ids: Vec<String>,
    liked_ids_set: HashSet<String>,
    disliked_ids: HashSet<String>,
    liked_albums_ids: HashSet<u32>,
    liked_artists_ids: HashSet<String>,
    disliked_artists_ids: HashSet<String>,
    liked_playlists_ids: HashSet<String>,
}

impl LikedCache {
    /// Applies a full-pull `collection/sync` snapshot (only the liked-tracks
    /// section is requested from the server, so that is all we handle).
    pub fn apply_liked_tracks(
        &mut self,
        revision: u64,
        liked_track_ids: Vec<String>,
        disliked_track_ids: Vec<String>,
    ) {
        self.revision = Some(revision);
        self.set_liked_ids(liked_track_ids);
        self.disliked_ids = disliked_track_ids
            .into_iter()
            .map(|id| id.to_base_id().to_string())
            .collect();
    }

    pub fn set_liked_ids(&mut self, ids: Vec<String>) {
        self.liked_ids = ids
            .into_iter()
            .map(|id| id.to_base_id().to_string())
            .collect();
        self.liked_ids_set = self.liked_ids.iter().cloned().collect();
    }

    pub fn snapshot(&self) -> LikedSnapshot {
        (self.liked_ids_set.clone(), self.disliked_ids.clone())
    }

    pub fn ordered_snapshot(&self) -> OrderedLikedSnapshot {
        (self.liked_ids.clone(), self.disliked_ids.clone())
    }

    pub fn set_like_status(&mut self, track_id: &str, liked: bool) {
        let base_id = track_id.to_base_id().to_string();
        if liked {
            if self.liked_ids_set.insert(base_id.clone()) {
                // Add new likes to the beginning
                self.liked_ids.insert(0, base_id);
            }
        } else if self.liked_ids_set.remove(&base_id) {
            self.liked_ids.retain(|id| id != &base_id);
        }
    }

    pub fn set_dislike_status(&mut self, track_id: &str, disliked: bool) {
        let base_id = track_id.to_base_id().to_string();
        if disliked {
            self.disliked_ids.insert(base_id);
        } else {
            self.disliked_ids.remove(&base_id);
        }
    }

    pub fn set_album_like_status(&mut self, album_id: u32, liked: bool) {
        if liked {
            self.liked_albums_ids.insert(album_id);
        } else {
            self.liked_albums_ids.remove(&album_id);
        }
    }

    pub fn set_artist_like_status(&mut self, artist_id: &str, liked: bool) {
        if liked {
            self.liked_artists_ids.insert(artist_id.to_string());
        } else {
            self.liked_artists_ids.remove(artist_id);
        }
    }

    pub fn set_artist_dislike_status(&mut self, artist_id: &str, disliked: bool) {
        if disliked {
            self.disliked_artists_ids.insert(artist_id.to_string());
        } else {
            self.disliked_artists_ids.remove(artist_id);
        }
    }

    pub fn playlist_key(owner_uid: u64, kind: u32) -> String {
        format!("{}:{}", owner_uid, kind)
    }

    pub fn set_playlist_like_status(&mut self, owner_uid: u64, kind: u32, liked: bool) {
        let key = Self::playlist_key(owner_uid, kind);
        if liked {
            self.liked_playlists_ids.insert(key);
        } else {
            self.liked_playlists_ids.remove(&key);
        }
    }

    pub fn is_album_liked(&self, album_id: u32) -> bool {
        self.liked_albums_ids.contains(&album_id)
    }

    pub fn is_artist_liked(&self, artist_id: &str) -> bool {
        self.liked_artists_ids.contains(artist_id)
    }

    pub fn is_artist_disliked(&self, artist_id: &str) -> bool {
        self.disliked_artists_ids.contains(artist_id)
    }

    pub fn is_playlist_liked(&self, owner_uid: u64, kind: u32) -> bool {
        self.liked_playlists_ids
            .contains(&Self::playlist_key(owner_uid, kind))
    }

    pub fn is_liked(&self, track_id: &str) -> bool {
        self.liked_ids_set.contains(track_id.to_base_id())
    }

    pub fn is_disliked(&self, track_id: &str) -> bool {
        self.disliked_ids.contains(track_id.to_base_id())
    }
}
