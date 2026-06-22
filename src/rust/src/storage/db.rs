use crate::api::models::TrackArtistDto;
use crate::storage::models::*;
use std::path::PathBuf;
use toasty::Db;
use tokio::sync::OnceCell;

/// Default TTL for cached images: 7 days in seconds
const DEFAULT_CACHE_TTL_SECS: i64 = 7 * 24 * 60 * 60;

static SCHEMA_PUSHED: OnceCell<()> = OnceCell::const_new();

pub struct AppDatabase {
    pub db: Db,
}

#[derive(Debug, Clone)]
pub struct TrackMetadata {
    pub id: String,
    pub title: String,
    pub version: Option<String>,
    pub artists: Vec<TrackArtistDto>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub cover_url: Option<String>,
    pub duration_ms: u64,
}

impl AppDatabase {
    pub async fn init(base_path: Option<PathBuf>) -> toasty::Result<Self> {
        let db_path = if let Some(path) = base_path {
            std::fs::create_dir_all(&path).ok();
            path.join("yamusic_v2.db")
        } else if let Some(proj_dirs) = directories::ProjectDirs::from("com", "yamusic", "yamusic")
        {
            let data_dir = proj_dirs.data_dir();
            std::fs::create_dir_all(data_dir).ok();
            data_dir.join("yamusic_v2.db")
        } else {
            PathBuf::from("yamusic_v2.db")
        };

        let db_url = format!("sqlite:{}", db_path.to_string_lossy());

        let db = Db::builder()
            .models(toasty::models!(crate::*))
            .connect(&db_url)
            .await?;

        SCHEMA_PUSHED
            .get_or_init(|| async {
                if let Err(_e) = db.push_schema().await {
                    // Toasty's push_schema does not use IF NOT EXISTS and will return an error
                    // if the tables already exist in the database.
                }
            })
            .await;

        Ok(Self { db })
    }

    pub async fn save_auth_token(&mut self, token: &str, user_id: u64) -> toasty::Result<()> {
        self.save_setting("auth_token", &(token.to_string(), user_id)).await
    }

    pub async fn load_auth_token(&mut self) -> toasty::Result<Option<(String, u64)>> {
        self.load_setting("auth_token").await
    }

    pub async fn delete_auth_token(&mut self) -> toasty::Result<()> {
        let _ = AppSetting::delete_by_key(&mut self.db, "auth_token").await;
        Ok(())
    }

    pub async fn update_cache_metadata(
        &mut self,
        url: &str,
        file_path: &str,
        size: u64,
        etag: Option<&str>,
    ) -> toasty::Result<()> {
        let now = chrono::Utc::now().timestamp();
        let expires_at = now + DEFAULT_CACHE_TTL_SECS;
        let existing = CacheMetadata::filter_by_url(url).first().exec(&mut self.db).await?;
        if let Some(mut cache) = existing {
            cache
                .update()
                .last_access_at(now)
                .size(size)
                .etag(etag.map(|s| s.to_string()))
                .expires_at(expires_at)
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(CacheMetadata {
                url: url.to_string(),
                file_path: file_path.to_string(),
                size,
                last_access_at: now,
                created_at: now,
                expires_at,
                etag: etag.map(|s| s.to_string()),
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn get_cache_metadata(
        &mut self,
        url: &str,
    ) -> toasty::Result<Option<(String, Option<String>, bool)>> {
        let res = CacheMetadata::filter_by_url(url).first().exec(&mut self.db).await?;
        if let Some(mut cache) = res {
            let now = chrono::Utc::now().timestamp();
            let is_expired = now >= cache.expires_at;

            if !is_expired {
                let new_expires = now + DEFAULT_CACHE_TTL_SECS;
                cache
                    .update()
                    .last_access_at(now)
                    .expires_at(new_expires)
                    .exec(&mut self.db)
                    .await?;
            }
            return Ok(Some((
                cache.file_path.clone(),
                cache.etag.clone(),
                is_expired,
            )));
        }
        Ok(None)
    }

    pub async fn prune_expired(&mut self) -> toasty::Result<Vec<String>> {
        let now = chrono::Utc::now().timestamp();
        let all: Vec<CacheMetadata> =
            CacheMetadata::filter(CacheMetadata::fields().expires_at().le(now))
                .exec(&mut self.db)
                .await?;
        let paths: Vec<String> = all.into_iter().map(|c| c.file_path).collect();

        if !paths.is_empty() {
            CacheMetadata::filter(CacheMetadata::fields().expires_at().le(now))
                .delete()
                .exec(&mut self.db)
                .await?;
        }
        Ok(paths)
    }

    pub async fn prune_cache(&mut self, max_size_bytes: i64) -> toasty::Result<Vec<String>> {
        let mut all: Vec<CacheMetadata> = CacheMetadata::all().exec(&mut self.db).await?;
        let current_size: u64 = all.iter().map(|c| c.size).sum();

        if current_size as i64 <= max_size_bytes {
            return Ok(vec![]);
        }

        all.sort_by_key(|c| c.last_access_at);
        let target_size = (max_size_bytes as f64 * 0.8) as u64;
        let mut to_delete = Vec::new();
        let mut deleted_size = 0u64;

        for c in all {
            if current_size - deleted_size <= target_size {
                break;
            }
            to_delete.push(c.file_path.clone());
            deleted_size += c.size;
            let _ = CacheMetadata::delete_by_url(&mut self.db, &c.url).await;
        }

        Ok(to_delete)
    }

    pub async fn get_cache_size(&mut self) -> toasty::Result<i64> {
        let all: Vec<CacheMetadata> = CacheMetadata::all().exec(&mut self.db).await?;
        Ok(all.iter().map(|c| c.size as i64).sum())
    }

    pub async fn clear_cache_metadata(&mut self) -> toasty::Result<()> {
        CacheMetadata::all().delete().exec(&mut self.db).await?;
        Ok(())
    }

    pub async fn save_playback_state(
        &mut self,
        track_id: &str,
        position_ms: u64,
        is_playing: bool,
    ) -> toasty::Result<()> {
        self.save_setting("playback_state", &(track_id.to_string(), position_ms, is_playing)).await
    }

    pub async fn load_playback_state(&mut self) -> toasty::Result<Option<(String, u64, bool)>> {
        self.load_setting("playback_state").await
    }

    pub async fn save_download_path(&mut self, path: &str) -> toasty::Result<()> {
        self.save_setting("download_path", &path.to_string()).await
    }

    pub async fn load_download_path(&mut self) -> toasty::Result<Option<String>> {
        self.load_setting("download_path").await
    }

    pub async fn save_liked_tracks(&mut self, track_ids: &[String]) -> toasty::Result<()> {
        self.save_setting("liked_tracks", &track_ids.to_vec()).await
    }

    pub async fn load_liked_tracks(&mut self) -> toasty::Result<Vec<String>> {
        Ok(self.load_setting("liked_tracks").await?.unwrap_or_default())
    }

    pub async fn add_liked_track(&mut self, track_id: &str) -> toasty::Result<()> {
        let mut tracks = self.load_liked_tracks().await?;
        if !tracks.iter().any(|x| x == track_id) {
            tracks.push(track_id.to_string());
            self.save_liked_tracks(&tracks).await?;
        }
        Ok(())
    }

    pub async fn remove_liked_track(&mut self, track_id: &str) -> toasty::Result<()> {
        let mut tracks = self.load_liked_tracks().await?;
        if let Some(pos) = tracks.iter().position(|x| x == track_id) {
            tracks.remove(pos);
            self.save_liked_tracks(&tracks).await?;
        }
        Ok(())
    }

    pub async fn upsert_track_metadata(&mut self, metadata: TrackMetadata) -> toasty::Result<()> {
        let res = TrackMetadataEntity::filter_by_track_id(&metadata.id).first().exec(&mut self.db).await?;
        if let Some(mut entity) = res {
            entity
                .update()
                .title(metadata.title)
                .version(metadata.version)
                .album(metadata.album)
                .album_id(metadata.album_id)
                .cover_url(metadata.cover_url)
                .duration_ms(metadata.duration_ms)
                .exec(&mut self.db)
                .await?;

            let artists: Vec<TrackMetadataArtist> =
                TrackMetadataArtist::filter_by_track_metadata_entity_id(&metadata.id)
                    .exec(&mut self.db)
                    .await?;
            for a in artists {
                let _ = a.delete().exec(&mut self.db).await;
            }
        } else {
            toasty::create!(TrackMetadataEntity {
                track_id: metadata.id.clone(),
                title: metadata.title,
                version: metadata.version,
                album: metadata.album,
                album_id: metadata.album_id,
                cover_url: metadata.cover_url,
                duration_ms: metadata.duration_ms,
            })
            .exec(&mut self.db)
            .await?;
        }

        for (i, artist) in metadata.artists.into_iter().enumerate() {
            toasty::create!(TrackMetadataArtist {
                id: format!("{}_{}_{}", metadata.id, artist.id, i),
                track_metadata_entity_id: metadata.id.clone(),
                artist_id: artist.id,
                name: artist.name,
                position: i as i64,
            })
            .exec(&mut self.db)
            .await?;
        }

        Ok(())
    }

    pub async fn get_track_metadata(
        &mut self,
        track_ids: &[String],
    ) -> toasty::Result<Vec<TrackMetadata>> {
        if track_ids.is_empty() {
            return Ok(vec![]);
        }

        let mut results = Vec::new();

        for chunk in track_ids.chunks(900) {
            let entities: Vec<TrackMetadataEntity> = TrackMetadataEntity::filter(
                TrackMetadataEntity::fields().track_id().in_list(chunk),
            )
            .include(TrackMetadataEntity::fields().artists())
            .exec(&mut self.db)
            .await?;

            for entity in entities {
                let track_artists: &[TrackMetadataArtist] = entity.artists.get();
                let mut track_artists_refs: Vec<&TrackMetadataArtist> = track_artists.iter().collect();
                track_artists_refs.sort_by_key(|a| a.position);
                
                let mut artist_dtos = Vec::new();
                for a in track_artists_refs {
                    artist_dtos.push(TrackArtistDto {
                        id: a.artist_id.clone(),
                        name: a.name.clone(),
                    });
                }

                results.push(TrackMetadata {
                    id: entity.track_id,
                    title: entity.title,
                    version: entity.version,
                    artists: artist_dtos,
                    album: entity.album,
                    album_id: entity.album_id,
                    cover_url: entity.cover_url,
                    duration_ms: entity.duration_ms,
                });
            }
        }

        Ok(results)
    }

    pub async fn save_equalizer(&mut self, enabled: bool, bands: &[f32]) -> toasty::Result<()> {
        self.save_setting("equalizer", &(enabled, bands)).await
    }

    pub async fn load_equalizer(&mut self) -> toasty::Result<Option<(bool, Vec<f32>)>> {
        self.load_setting("equalizer").await
    }

    pub async fn save_effect(
        &mut self,
        id: &str,
        enabled: bool,
        params: &[f32],
    ) -> toasty::Result<()> {
        self.save_setting(&format!("effect_{}", id), &(enabled, params)).await
    }

    pub async fn load_effect(&mut self, id: &str) -> toasty::Result<Option<(bool, Vec<f32>)>> {
        self.load_setting(&format!("effect_{}", id)).await
    }

    pub async fn save_setting<T: serde::Serialize>(&mut self, key: &str, value: &T) -> toasty::Result<()> {
        let val = serde_json::to_string(value).unwrap_or_default();
        self.save_app_setting(key, &val).await
    }

    pub async fn load_setting<T: serde::de::DeserializeOwned>(&mut self, key: &str) -> toasty::Result<Option<T>> {
        let val = self.load_app_setting(key).await?;
        if let Some(v) = val
            && let Ok(parsed) = serde_json::from_str(&v) {
                return Ok(Some(parsed));
            }
        Ok(None)
    }

    pub async fn save_app_setting(&mut self, key: &str, value: &str) -> toasty::Result<()> {
        let res = AppSetting::filter_by_key(key).first().exec(&mut self.db).await?;
        if let Some(mut setting) = res {
            setting
                .update()
                .value(value.to_string())
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(AppSetting {
                key: key.to_string(),
                value: value.to_string(),
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    async fn load_app_setting(&mut self, key: &str) -> toasty::Result<Option<String>> {
        let res = AppSetting::filter_by_key(key).first().exec(&mut self.db).await?;
        if let Some(setting) = res {
            Ok(Some(setting.value))
        } else {
            Ok(None)
        }
    }
}
