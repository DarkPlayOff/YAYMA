use super::*;
use yandex_music::api::playlist::{
    change_playlist_visibility::ChangePlaylistVisibilityOptions,
    create_playlist::CreatePlaylistOptions, delete_playlist::DeletePlaylistOptions,
    get_all_playlists::GetAllPlaylistsOptions, get_playlists::GetPlaylistsOptions,
    modify_playlist::ModifyPlaylistOptions, rename_playlist::RenamePlaylistOptions,
};
use yandex_music::model::{
    playlist::{
        Playlist,
        modify::{Diff, DiffOp},
    },
    track::TrackShort,
};

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
        album_id: String,
    ) -> Result<()> {
        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        let diff = Diff::new(DiffOp::insert(0), vec![track]);
        self.modify_playlist_with_revision_retry(kind, diff).await?;
        Ok(())
    }

    pub async fn remove_track_from_playlist(
        &self,
        kind: u32,
        track_id: String,
        album_id: String,
    ) -> Result<()> {
        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        let diff = Diff::new(DiffOp::delete(0, 1), vec![track]);
        self.modify_playlist_with_revision_retry(kind, diff).await?;
        Ok(())
    }

    pub async fn move_track_in_playlist(
        &self,
        kind: u32,
        from_index: usize,
        to_index: usize,
        track_id: String,
        album_id: String,
    ) -> Result<()> {
        let track = TrackShort {
            id: track_id,
            album_id: Some(album_id),
        };

        // NOTE: yandex-music 0.7.0 DiffOp supports only Insert/Delete (no atomic
        // move/reorder op), so a move stays a delete+insert pair. If the insert
        // fails, put the track back where it was: losing it from the playlist is
        // not recoverable from the UI, while an extra restore at worst leaves a
        // duplicate. Inserting a copy first instead would assume the server
        // accepts duplicate entries, which is not something we control.
        let diff_delete = Diff::new(
            DiffOp::delete(from_index, from_index + 1),
            vec![track.clone()],
        );
        let diff_insert = Diff::new(DiffOp::insert(to_index), vec![track.clone()]);

        self.modify_playlist_with_revision_retry(kind, diff_delete)
            .await?;
        if let Err(e) = self
            .modify_playlist_with_revision_retry(kind, diff_insert)
            .await
        {
            let restore = Diff::new(DiffOp::insert(from_index), vec![track]);
            if let Err(restore_error) = self
                .modify_playlist_with_revision_retry(kind, restore)
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

    /// Run one `change-relative` diff against the current revision; on HTTP 412
    /// Precondition Failed do a single `fetch_playlist_bare` refetch and one retry.
    /// A second 412 (or any other error) is returned to the caller (RELOAD semantics
    /// are decided upstream). At most 1 retry per call.
    async fn modify_playlist_with_revision_retry(&self, kind: u32, diff: Diff) -> Result<Playlist> {
        let playlist = self.fetch_playlist_bare(kind).await?;
        let opts = ModifyPlaylistOptions::new(self.user_id, kind, diff.clone(), playlist.revision);
        match self.client.modify_playlist(&opts).await {
            Ok(updated) => Ok(updated),
            Err(e) if is_precondition_failed(&e) => {
                let fresh = self.fetch_playlist_bare(kind).await?;
                let retry_opts =
                    ModifyPlaylistOptions::new(self.user_id, kind, diff, fresh.revision);
                Ok(self.client.modify_playlist(&retry_opts).await?)
            }
            Err(e) => Err(e.into()),
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
