use super::*;
use crate::util::track::{CleanId, extract_ids};
use yandex_music::api::playlist::{
    change_playlist_visibility::ChangePlaylistVisibilityOptions,
    create_playlist::CreatePlaylistOptions, delete_playlist::DeletePlaylistOptions,
    get_all_playlists::GetAllPlaylistsOptions, get_playlists::GetPlaylistsOptions,
    rename_playlist::RenamePlaylistOptions,
};
use yandex_music::model::playlist::{Playlist, PlaylistTracks};

/// `diff` field of `POST /users/{uid}/playlists/{kind}/change-relative`.
///
/// Hand-built rather than the crate's `Diff`: its `TrackShort` always
/// serializes `albumId: null`, which the server answers with `400 validate` for
/// a track without an album (an upload). Neither op needs the album, and
/// `delete` takes no track list at all.
fn insert_diff(at: usize, track_id: &str) -> serde_json::Value {
    serde_json::json!({
        "op": "insert",
        "at": at,
        "tracks": [{ "id": track_id.to_base_id() }],
    })
}

fn delete_diff(from: usize) -> serde_json::Value {
    serde_json::json!({ "op": "delete", "from": from, "to": from + 1 })
}

/// Index of [track_id] in the playlist's current track list, preferring
/// [prefer] when that entry is the same track (a playlist may hold it twice).
///
/// `delete` addresses tracks by position, so the diff has to point at the
/// track's own index, not at 0.
fn playlist_track_index(
    tracks: Option<&PlaylistTracks>,
    track_id: &str,
    prefer: Option<usize>,
) -> Option<usize> {
    let ids = extract_ids(tracks?);
    let matches = |id: &String| id.as_str().to_base_id() == track_id.to_base_id();
    if prefer.is_some_and(|i| ids.get(i).is_some_and(matches)) {
        return prefer;
    }
    ids.iter().position(matches)
}

/// A `delete` diff for [track_id] at its current position. `None` when the
/// track is not in the playlist any more.
fn track_delete_diff(
    tracks: Option<&PlaylistTracks>,
    track_id: &str,
    prefer: Option<usize>,
) -> Option<serde_json::Value> {
    playlist_track_index(tracks, track_id, prefer).map(delete_diff)
}

impl ApiService {
    pub async fn fetch_all_playlists(&self) -> Result<Vec<Playlist>> {
        let opts = GetAllPlaylistsOptions::new(self.user_id);
        Ok(self.client.get_all_playlists(&opts).await?)
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

    /// Kinds out of [kinds] whose playlist already contains [track_id].
    ///
    /// One request for all playlists with id-only tracks (`richTracks=false`).
    /// The full-track path costs one `fetch_tracks(50)` round trip per 50
    /// tracks for every playlist, and the track ids are all this needs.
    pub async fn fetch_playlists_containing_track(
        &self,
        kinds: &[u32],
        track_id: &str,
    ) -> Result<Vec<u32>> {
        if kinds.is_empty() {
            return Ok(Vec::new());
        }
        let kinds_param = kinds
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let url = format!(
            "{API_RU}/users/{}/playlists?kinds={}&withTracks=true&richTracks=false",
            self.user_id, kinds_param
        );
        // Raw JSON on purpose: the crate's untagged `PlaylistTracks` fails the
        // whole playlist if one entry is shaped differently, and a missed id is
        // a wrong checkmark here.
        let body: serde_json::Value = send_with_retry(|| self.http_client.get(&url))
            .await?
            .json()
            .await?;
        Ok(containing_kinds(&body, track_id))
    }

    pub async fn add_track_to_playlist(
        &self,
        kind: u32,
        track_id: String,
        _album_id: String,
    ) -> Result<()> {
        // shortcut: the album id is unused (the server accepts an insert
        // without it) but stays for the generated FRB binding; drop it on the
        // next regen.
        let diff = insert_diff(0, &track_id);
        self.modify_playlist_with_revision_retry(kind, |_| Some(diff.clone()))
            .await?;
        Ok(())
    }

    pub async fn remove_track_from_playlist(
        &self,
        kind: u32,
        track_id: String,
        _album_id: String,
    ) -> Result<()> {
        // shortcut: the album id is unused — `delete` is positional — but it
        // stays for the generated FRB binding; drop it on the next regen.
        self.modify_playlist_with_revision_retry(kind, |playlist| {
            track_delete_diff(playlist.tracks.as_ref(), &track_id, None)
        })
        .await?;
        Ok(())
    }

    pub async fn move_track_in_playlist(
        &self,
        kind: u32,
        from_index: usize,
        to_index: usize,
        track_id: String,
        _album_id: String,
    ) -> Result<()> {
        // NOTE: the API has no atomic move op, so a move stays a delete+insert
        // pair. If the insert fails, put the track back where it was: losing it
        // from the playlist is not recoverable from the UI, while an extra
        // restore at worst leaves a duplicate. Inserting a copy first instead
        // would assume the server accepts duplicate entries, which is not
        // something we control.
        let diff_insert = insert_diff(to_index, &track_id);

        // Delete by the track's current position, not by the UI index: a stale
        // index would remove whatever moved into that slot instead. `from_index`
        // only breaks the tie when the playlist holds the track twice.
        let applied = self
            .modify_playlist_with_revision_retry(kind, |playlist| {
                track_delete_diff(playlist.tracks.as_ref(), &track_id, Some(from_index))
            })
            .await?;
        // The track is gone (removed elsewhere): inserting now would add it
        // back instead of moving it.
        if !applied {
            return Ok(());
        }
        if let Err(e) = self
            .modify_playlist_with_revision_retry(kind, |_| Some(diff_insert.clone()))
            .await
        {
            let restore = insert_diff(from_index, &track_id);
            if let Err(restore_error) = self
                .modify_playlist_with_revision_retry(kind, |_| Some(restore.clone()))
                .await
            {
                tracing::error!(
                    error = %restore_error,
                    "playlist_move_restore_failed"
                );
            }
            return Err(e);
        }

        Ok(())
    }

    /// Run the diff built from the current playlist against its revision; on
    /// HTTP 412 Precondition Failed refetch the revision once and rebuild the
    /// diff from the fresh playlist. A second 412 (or any other error) goes to
    /// the caller (RELOAD semantics are decided upstream).
    ///
    /// Returns whether anything was sent: `false` when [diff_for] returns
    /// `None`, i.e. the change no longer applies (e.g. the track was already
    /// removed).
    async fn modify_playlist_with_revision_retry<F>(&self, kind: u32, diff_for: F) -> Result<bool>
    where
        F: Fn(&Playlist) -> Option<serde_json::Value>,
    {
        let playlist = self.fetch_playlist_bare(kind).await?;
        let Some(diff) = diff_for(&playlist) else {
            return Ok(false);
        };
        if self.change_playlist(kind, &diff, playlist.revision).await? {
            return Ok(true);
        }
        let fresh = self.fetch_playlist_bare(kind).await?;
        let Some(diff) = diff_for(&fresh) else {
            return Ok(false);
        };
        if self.change_playlist(kind, &diff, fresh.revision).await? {
            Ok(true)
        } else {
            Err("playlist revision conflict".into())
        }
    }

    /// POST one `change-relative` diff; `Ok(false)` means HTTP 412, i.e. the
    /// revision is stale and the update was not applied.
    async fn change_playlist(
        &self,
        kind: u32,
        diff: &serde_json::Value,
        revision: u32,
    ) -> Result<bool> {
        let url = format!(
            "{API_NET}/users/{}/playlists/{kind}/change-relative",
            self.user_id
        );
        let response = self
            .http_client
            .post(&url)
            .form(&[
                ("revision", revision.to_string()),
                ("diff", serde_json::json!({ "diff": diff }).to_string()),
            ])
            .send()
            .await?;
        match response.status() {
            status if status.is_success() => Ok(true),
            reqwest::StatusCode::PRECONDITION_FAILED => Ok(false),
            status => {
                let body = response.text().await.unwrap_or_default();
                Err(format!("HTTP {status}: {body}").into())
            }
        }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn playlist_track_index_uses_the_matching_entry_not_zero() {
        let tracks: PlaylistTracks = serde_json::from_value(json!([
            {"id": 11, "albumId": 1, "timestamp": "2026-01-01T00:00:00Z"},
            {"id": 22, "albumId": 2, "timestamp": "2026-01-01T00:00:00Z"},
        ]))
        .unwrap();

        assert_eq!(playlist_track_index(Some(&tracks), "22", None), Some(1));
        assert_eq!(playlist_track_index(Some(&tracks), "22:2", None), Some(1));
        assert_eq!(playlist_track_index(Some(&tracks), "99", None), None);
        assert_eq!(playlist_track_index(None, "22", None), None);

        // `prefer` breaks the tie only when that slot holds the same track.
        assert_eq!(playlist_track_index(Some(&tracks), "22", Some(1)), Some(1));
        assert_eq!(playlist_track_index(Some(&tracks), "22", Some(0)), Some(1));
        assert_eq!(playlist_track_index(Some(&tracks), "22", Some(9)), Some(1));
    }

    #[test]
    fn diffs_carry_no_album_id() {
        // The server answers `400 validate` to `"albumId": null`, which is what
        // the crate's `TrackShort` always sends for a track without an album.
        assert_eq!(
            insert_diff(0, "22:2").to_string(),
            r#"{"at":0,"op":"insert","tracks":[{"id":"22"}]}"#
        );
        assert_eq!(
            track_delete_diff(
                Some(
                    &serde_json::from_value::<PlaylistTracks>(json!([
                        {"id": 11, "albumId": 1, "timestamp": "2026-01-01T00:00:00Z"},
                        {"id": 22, "albumId": 2, "timestamp": "2026-01-01T00:00:00Z"},
                    ]))
                    .unwrap()
                ),
                "22",
                None
            )
            .unwrap()
            .to_string(),
            r#"{"from":1,"op":"delete","to":2}"#
        );
        assert!(track_delete_diff(None, "22", None).is_none());
    }
}
