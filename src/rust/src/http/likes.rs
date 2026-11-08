use super::*;
use crate::util::track::CleanId;
use yandex_music::api::{
    album::{add_liked_album::AddLikedAlbumOptions, remove_liked_album::RemoveLikedAlbumOptions},
    artist::{
        add_disliked_artist::AddDislikedArtistOptions, add_liked_artist::AddLikedArtistOptions,
        remove_disliked_artist::RemoveDislikedArtistOptions,
        remove_liked_artist::RemoveLikedArtistOptions,
    },
    playlist::{
        add_liked_playlist::AddLikedPlaylistOptions,
        remove_liked_playlist::RemoveLikedPlaylistOptions,
    },
    track::{
        add_disliked_tracks::AddDislikedTracksOptions, add_liked_tracks::AddLikedTracksOptions,
        get_disliked_tracks::GetDislikedTracksOptions,
        remove_disliked_tracks::RemoveDislikedTracksOptions,
        remove_liked_tracks::RemoveLikedTracksOptions,
    },
};

impl ApiService {
    pub async fn add_like_track(&self, track_id: String) -> Result<()> {
        let opts = AddLikedTracksOptions::new(self.user_id, vec![track_id]);
        // yandex_music crate returns Err if the response JSON has no `revision`
        // (InvalidValue), so `?` here rejects non-OK responses without revision.
        let _revision: u64 = self.client.add_liked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_track(&self, track_id: String) -> Result<()> {
        let opts = RemoveLikedTracksOptions::new(self.user_id, vec![track_id]);
        // Same revision check as above: Err if no `revision` in response.
        let _revision: u64 = self.client.remove_liked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn add_dislike_track(&self, track_id: String) -> Result<()> {
        let opts = AddDislikedTracksOptions::new(self.user_id, vec![track_id]);
        // Same revision check as above: Err if no `revision` in response.
        let _revision: u64 = self.client.add_disliked_tracks(&opts).await?;
        Ok(())
    }

    pub async fn remove_dislike_track(&self, track_id: String) -> Result<()> {
        let opts = RemoveDislikedTracksOptions::new(self.user_id, vec![track_id]);
        // Same revision check as above: Err if no `revision` in response.
        let _revision: u64 = self.client.remove_disliked_tracks(&opts).await?;
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

    pub async fn add_like_playlist(&self, owner_uid: u64, kind: u32) -> Result<()> {
        let opts = AddLikedPlaylistOptions::new(self.user_id, owner_uid, kind);
        self.client.add_liked_playlist(&opts).await?;
        Ok(())
    }

    pub async fn remove_like_playlist(&self, owner_uid: u64, kind: u32) -> Result<()> {
        let opts = RemoveLikedPlaylistOptions::new(self.user_id, owner_uid, kind);
        self.client.remove_liked_playlist(&opts).await?;
        Ok(())
    }

    pub async fn fetch_liked_ids(&self) -> Result<Vec<String>> {
        let opts =
            yandex_music::api::track::get_liked_tracks::GetLikedTracksOptions::new(self.user_id);
        let library = self.client.get_liked_tracks(&opts).await?;

        Ok(library.tracks.into_iter().map(|t| t.id).collect())
    }

    /// Authoritative disliked list, newest first. The in-memory cache only
    /// learns about dislikes from the revision-gated collection sync, which
    /// skips them once the stored revision is current, so a refresh has to ask
    /// the server.
    pub async fn fetch_disliked_ids(&self) -> Result<Vec<String>> {
        let opts = GetDislikedTracksOptions::new(self.user_id);
        let library = self.client.get_disliked_tracks(&opts).await?;

        let mut tracks = library.tracks;
        sort_disliked_tracks(&mut tracks);

        Ok(tracks
            .into_iter()
            .map(|t| t.id.to_base_id().to_string())
            .collect())
    }

    /// Revision-gated collection sync for liked tracks (mirrors the official
    /// desktop client): with a known `revision` the server answers
    /// `likedTracks: {info: {...}}` with **no `values`** when nothing changed
    /// (verified against the real API); the official client guards on exactly
    /// that shape. The bundled `yandex-music` crate instead requires `values`
    /// in every present section, so this parses the response here and reports
    /// `Unchanged` itself. Missing storage revision (`None`) sends
    /// `allValuesRequired: true` for the full snapshot.
    pub async fn sync_liked_tracks_collection(
        &self,
        revision: Option<u64>,
    ) -> Result<LikedTracksSync> {
        let option = match revision {
            Some(rev) => serde_json::json!({ "revision": rev }),
            None => serde_json::json!({ "allValuesRequired": true }),
        };
        let body = serde_json::json!({ "likedTracks": option });
        let response: serde_json::Value = send_with_retry(|| {
            self.client
                .inner
                .post(format!("{API_NET}/collection/sync"))
                .json(&body)
        })
        .await?
        .json()
        .await?;

        let section = &response["result"]["values"]["likedTracks"];
        let revision = section["info"]["revision"].as_u64();

        // Current revision: section is present but has no `values` key.
        let Some(values) = section.get("values") else {
            return Ok(LikedTracksSync::Unchanged);
        };
        let revision =
            revision.ok_or("likedTracks section carries no info.revision despite `values`")?;

        let parse_ids = |key: &str| -> Vec<String> {
            values[key]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .filter_map(|row| match &row["trackId"] {
                            serde_json::Value::String(id) => Some(id.clone()),
                            serde_json::Value::Number(n) => Some(n.to_string()),
                            _ => None,
                        })
                        .collect()
                })
                .unwrap_or_default()
        };

        Ok(LikedTracksSync::Changed {
            revision,
            liked_track_ids: parse_ids("liked"),
            disliked_track_ids: parse_ids("disliked"),
        })
    }
}

/// Newest dislike first; the id tie-break keeps equal timestamps stable, so the
/// list does not reshuffle between refreshes when two tracks were disliked in
/// the same second (or the server drops the sub-second precision).
fn sort_disliked_tracks(tracks: &mut [yandex_music::model::track::PartialTrack]) {
    tracks.sort_by(|a, b| b.timestamp.cmp(&a.timestamp).then_with(|| a.id.cmp(&b.id)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn disliked_tracks_sort_newest_first_and_stable_on_ties() {
        let mut tracks: Vec<yandex_music::model::track::PartialTrack> =
            serde_json::from_value(json!([
                {"id": 3, "timestamp": "2026-01-01T00:00:00+00:00"},
                {"id": 1, "timestamp": "2026-03-01T00:00:00+00:00"},
                {"id": 2, "timestamp": "2026-01-01T00:00:00+00:00"},
            ]))
            .unwrap();

        sort_disliked_tracks(&mut tracks);

        let ids: Vec<&str> = tracks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["1", "2", "3"]);
    }
}
