use super::*;
use yandex_music::api::{
    album::get_album::GetAlbumOptions,
    artist::{
        get_artist::GetArtistOptions, get_artist_albums::GetArtistAlbumsOptions,
        get_artist_tracks::ArtistTracksOptions,
    },
    playlist::get_playlists::GetPlaylistsOptions,
    search::get_search::SearchOptions,
    track::get_lyrics::GetLyricsOptions,
};
use yandex_music::model::{
    album::Album,
    artist::Artist,
    info::{lyrics::LyricsFormat, pager::Pager},
    playlist::Playlist,
    search::Search,
    track::Track,
};

impl ApiService {
    pub async fn search(&self, query: &str) -> Result<Search> {
        let opts = SearchOptions::new(query);
        Ok(self.client.search(&opts).await?)
    }

    pub async fn fetch_liked_tracks(&self) -> Result<Playlist> {
        self.fetch_first(
            self.client.get_playlists(
                &GetPlaylistsOptions::new(self.user_id)
                    .kinds([3u32])
                    .with_tracks(true),
            ),
        )
        .await
    }

    pub async fn fetch_liked_albums(&self) -> Result<Vec<Album>> {
        let url = format!("{API_RU}/users/{}/likes/albums?rich=true", self.user_id);
        let body: serde_json::Value = send_with_retry(|| self.http_client.get(&url))
            .await?
            .json()
            .await?;
        Ok(Self::extract_liked(&body, "albums", "album"))
    }

    pub async fn fetch_liked_artists(&self) -> Result<Vec<Artist>> {
        let url = format!(
            "{API_RU}/users/{}/likes/artists?with-timestamps=false",
            self.user_id
        );
        let body: serde_json::Value = send_with_retry(|| self.http_client.get(&url))
            .await?
            .json()
            .await?;
        Ok(Self::extract_liked(&body, "artists", "artist"))
    }

    /// Parses Yandex "likes" responses. The payload may arrive as a top-level array,
    /// `result: [..]`, `result: { <plural>: [..] }`, or `result: { likes: [..] }`.
    /// Each entry may be the object itself or wrapped as `{ id, timestamp, <singular>: {..} }`.
    fn extract_liked<T: serde::de::DeserializeOwned>(
        body: &serde_json::Value,
        plural_key: &str,
        singular_key: &str,
    ) -> Vec<T> {
        let Some(items) = Self::liked_items(body, plural_key) else {
            return vec![];
        };
        let mut skipped = 0usize;
        let mut first_error = None;
        let items = items
            .iter()
            .filter_map(|item| {
                let value = if item.get(singular_key).is_some() {
                    &item[singular_key]
                } else {
                    item
                };
                match serde_json::from_value::<T>(value.clone()) {
                    Ok(parsed) => Some(parsed),
                    Err(e) => {
                        // Silent drops made a server-side shape change look
                        // like "the user has fewer albums".
                        skipped += 1;
                        first_error.get_or_insert_with(|| e.to_string());
                        None
                    }
                }
            })
            .collect();
        if skipped > 0 {
            tracing::warn!(
                key = plural_key,
                skipped,
                error = first_error.as_deref().unwrap_or("-"),
                "liked_entries_skipped"
            );
        }
        items
    }

    fn liked_items<'a>(
        body: &'a serde_json::Value,
        plural_key: &str,
    ) -> Option<&'a Vec<serde_json::Value>> {
        let result = &body["result"];
        body.as_array()
            .or_else(|| result.as_array())
            .or_else(|| result[plural_key].as_array())
            .or_else(|| result["likes"].as_array())
            .or_else(|| result["library"][plural_key].as_array())
    }

    pub async fn fetch_lyrics(
        &self,
        track_id: String,
        format: LyricsFormat,
    ) -> Result<Option<String>> {
        let opts = GetLyricsOptions::new(track_id, format);
        match self.client.get_lyrics(&opts).await {
            Ok(lyrics) => {
                let url = lyrics.download_url;
                let text = self.client.inner.get(url).send().await?.text().await?;
                Ok(Some(text))
            }
            Err(_) => Ok(None),
        }
    }

    pub async fn fetch_album_with_tracks(&self, album_id: u32) -> Result<Album> {
        let opts = GetAlbumOptions::new(album_id).with_tracks();
        Ok(self.client.get_album(&opts).await?)
    }

    pub async fn fetch_artist(
        &self,
        artist_id: String,
    ) -> Result<yandex_music::model::artist::Artist> {
        let opts = GetArtistOptions::new(artist_id);
        Ok(self.client.get_artist(&opts).await?.artist)
    }

    pub async fn fetch_artist_albums(
        &self,
        artist_id: String,
        page: u32,
        page_size: u32,
    ) -> Result<Vec<Album>> {
        let opts = GetArtistAlbumsOptions::new(artist_id)
            .page(page)
            .page_size(page_size);
        Ok(self.client.get_artist_albums(&opts).await?.albums)
    }

    pub async fn fetch_artist_tracks_paginated(
        &self,
        artist_id: String,
        page: u32,
        page_size: u32,
    ) -> Result<(Vec<Track>, Pager)> {
        let opts = ArtistTracksOptions::new(artist_id)
            .page(page)
            .page_size(page_size);
        let result = self.client.get_artist_tracks(&opts).await?;
        Ok((result.tracks, result.pager))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extracts_wrapped_albums_from_top_level_array() {
        let body = json!([
            {
                "timestamp": "2026-05-26T00:00:00+00:00",
                "album": {
                    "id": 10,
                    "title": "Album title"
                }
            }
        ]);

        let albums: Vec<Album> = ApiService::extract_liked(&body, "albums", "album");

        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].id, Some(10));
        assert_eq!(albums[0].title.as_deref(), Some("Album title"));
    }

    #[test]
    fn extracts_direct_artists_from_top_level_array() {
        let body = json!([
            {
                "id": "20",
                "name": "Artist name"
            }
        ]);

        let artists: Vec<Artist> = ApiService::extract_liked(&body, "artists", "artist");

        assert_eq!(artists.len(), 1);
        assert_eq!(artists[0].id.as_deref(), Some("20"));
        assert_eq!(artists[0].name.as_deref(), Some("Artist name"));
    }

    #[test]
    fn extracts_direct_albums_from_library_shape() {
        let body = json!({
            "result": {
                "library": {
                    "albums": [
                        {
                            "id": 30,
                            "title": "Library album"
                        }
                    ]
                }
            }
        });

        let albums: Vec<Album> = ApiService::extract_liked(&body, "albums", "album");

        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].id, Some(30));
        assert_eq!(albums[0].title.as_deref(), Some("Library album"));
    }
}
