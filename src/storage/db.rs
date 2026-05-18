use crate::api::models::{AudioQuality, TrackArtistDto};
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
        let val = format!("{}:{}", token, user_id);
        let key = "auth_token".to_string();
        let existing = AppSetting::get_by_key(&mut self.db, &key).await;
        if let Ok(mut existing) = existing {
            existing.update().value(val).exec(&mut self.db).await?;
        } else {
            toasty::create!(AppSetting { key, value: val })
                .exec(&mut self.db)
                .await?;
        }
        Ok(())
    }

    pub async fn load_auth_token(&mut self) -> toasty::Result<Option<(String, u64)>> {
        let res = AppSetting::get_by_key(&mut self.db, "auth_token").await;
        if let Ok(setting) = res {
            let mut parts = setting.value.split(':');
            let token = parts.next().unwrap_or("").to_string();
            let uid = parts.next().unwrap_or("0").parse().unwrap_or(0);
            if !token.is_empty() {
                return Ok(Some((token, uid)));
            }
        }
        Ok(None)
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
        let existing = CacheMetadata::get_by_url(&mut self.db, url).await;
        if let Ok(mut cache) = existing {
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
        let res = CacheMetadata::get_by_url(&mut self.db, url).await;
        if let Ok(mut cache) = res {
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
        let id = "1".to_string();
        let res = PlaybackState::get_by_id(&mut self.db, &id).await;
        if let Ok(mut state) = res {
            state
                .update()
                .track_id(track_id.to_string())
                .position_ms(position_ms)
                .is_playing(is_playing)
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(PlaybackState {
                id,
                track_id: track_id.to_string(),
                position_ms,
                is_playing,
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn load_playback_state(&mut self) -> toasty::Result<Option<(String, u64, bool)>> {
        let res = PlaybackState::get_by_id(&mut self.db, "1").await;
        if let Ok(state) = res {
            Ok(Some((
                state.track_id.clone(),
                state.position_ms,
                state.is_playing,
            )))
        } else {
            Ok(None)
        }
    }

    pub async fn save_download_path(&mut self, path: &str) -> toasty::Result<()> {
        let id = "1".to_string();
        let res = DownloadPath::get_by_id(&mut self.db, &id).await;
        if let Ok(mut dp) = res {
            dp.update()
                .folder_path(path.to_string())
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(DownloadPath {
                id,
                folder_path: path.to_string(),
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn load_download_path(&mut self) -> toasty::Result<Option<String>> {
        let res = DownloadPath::get_by_id(&mut self.db, "1").await;
        if let Ok(dp) = res {
            Ok(Some(dp.folder_path.clone()))
        } else {
            Ok(None)
        }
    }

    pub async fn save_liked_tracks(&mut self, track_ids: &[String]) -> toasty::Result<()> {
        LikedTrack::all().delete().exec(&mut self.db).await?;

        if !track_ids.is_empty() {
            let mut batch = LikedTrack::create_many();
            for id in track_ids {
                batch = batch.item(toasty::create!(LikedTrack {
                    track_id: id.clone(),
                }));
            }
            batch.exec(&mut self.db).await?;
        }
        Ok(())
    }

    pub async fn load_liked_tracks(&mut self) -> toasty::Result<Vec<String>> {
        let all: Vec<LikedTrack> = LikedTrack::all().exec(&mut self.db).await?;
        Ok(all.into_iter().map(|t| t.track_id).collect())
    }

    pub async fn add_liked_track(&mut self, track_id: &str) -> toasty::Result<()> {
        if LikedTrack::get_by_track_id(&mut self.db, track_id)
            .await
            .is_err()
        {
            toasty::create!(LikedTrack {
                track_id: track_id.to_string(),
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn remove_liked_track(&mut self, track_id: &str) -> toasty::Result<()> {
        let _ = LikedTrack::delete_by_track_id(&mut self.db, track_id).await;
        Ok(())
    }

    pub async fn upsert_track_metadata(&mut self, metadata: TrackMetadata) -> toasty::Result<()> {
        let res = TrackMetadataEntity::get_by_track_id(&mut self.db, &metadata.id).await;
        if let Ok(mut entity) = res {
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

        let entities: Vec<TrackMetadataEntity> = TrackMetadataEntity::filter(
            TrackMetadataEntity::fields().track_id().in_list(track_ids),
        )
        .exec(&mut self.db)
        .await?;

        let mut results = Vec::new();
        for entity in entities {
            let artists: Vec<TrackMetadataArtist> =
                TrackMetadataArtist::filter_by_track_metadata_entity_id(&entity.track_id)
                    .exec(&mut self.db)
                    .await?;
            let mut artist_dtos = Vec::new();
            let mut sorted_artists = artists;
            sorted_artists.sort_by_key(|a| a.position);
            for a in sorted_artists {
                artist_dtos.push(TrackArtistDto {
                    id: a.artist_id.clone(),
                    name: a.name.clone(),
                });
            }
            results.push(TrackMetadata {
                id: entity.track_id.clone(),
                title: entity.title.clone(),
                version: entity.version.clone(),
                artists: artist_dtos,
                album: entity.album.clone(),
                album_id: entity.album_id.clone(),
                cover_url: entity.cover_url.clone(),
                duration_ms: entity.duration_ms,
            });
        }
        Ok(results)
    }

    pub async fn search_liked_tracks(&mut self, query: &str) -> toasty::Result<Vec<String>> {
        let q = query.to_lowercase();
        let likes: Vec<LikedTrack> = LikedTrack::all().exec(&mut self.db).await?;
        let mut matches = Vec::new();
        for l in likes {
            if let Ok(m) = TrackMetadataEntity::get_by_track_id(&mut self.db, &l.track_id).await {
                if m.title.to_lowercase().contains(&q)
                    || m.album.as_deref().unwrap_or("").to_lowercase().contains(&q)
                {
                    matches.push(l.track_id.clone());
                    continue;
                }
                let artists: Vec<TrackMetadataArtist> =
                    TrackMetadataArtist::filter_by_track_metadata_entity_id(&l.track_id)
                        .exec(&mut self.db)
                        .await?;
                for a in artists {
                    if a.name.to_lowercase().contains(&q) {
                        matches.push(l.track_id.clone());
                        break;
                    }
                }
            }
        }
        Ok(matches)
    }

    pub async fn save_equalizer(&mut self, enabled: bool, bands: &[f32]) -> toasty::Result<()> {
        let bands_json = serde_json::to_string(bands).unwrap_or_else(|_| "[]".to_string());
        let id = "1".to_string();
        if let Ok(mut eq) = EqualizerSetting::get_by_id(&mut self.db, &id).await {
            eq.update()
                .enabled(enabled)
                .bands(bands_json)
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(EqualizerSetting {
                id,
                enabled,
                bands: bands_json,
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn load_equalizer(&mut self) -> toasty::Result<Option<(bool, Vec<f32>)>> {
        if let Ok(eq) = EqualizerSetting::get_by_id(&mut self.db, "1").await {
            let bands: Vec<f32> = serde_json::from_str(&eq.bands).unwrap_or_default();
            Ok(Some((eq.enabled, bands)))
        } else {
            Ok(None)
        }
    }

    pub async fn save_effect(
        &mut self,
        id: &str,
        enabled: bool,
        params: &[f32],
    ) -> toasty::Result<()> {
        let params_json = serde_json::to_string(params).unwrap_or_else(|_| "[]".to_string());
        if let Ok(mut effect) = EffectSetting::get_by_effect_id(&mut self.db, id).await {
            effect
                .update()
                .enabled(enabled)
                .params(params_json)
                .exec(&mut self.db)
                .await?;
        } else {
            toasty::create!(EffectSetting {
                effect_id: id.to_string(),
                enabled,
                params: params_json,
            })
            .exec(&mut self.db)
            .await?;
        }
        Ok(())
    }

    pub async fn load_effect(&mut self, id: &str) -> toasty::Result<Option<(bool, Vec<f32>)>> {
        if let Ok(effect) = EffectSetting::get_by_effect_id(&mut self.db, id).await {
            let params: Vec<f32> = serde_json::from_str(&effect.params).unwrap_or_default();
            Ok(Some((effect.enabled, params)))
        } else {
            Ok(None)
        }
    }

    pub async fn save_volume(&mut self, volume: u8) -> toasty::Result<()> {
        self.save_app_setting("volume", &volume.to_string()).await
    }

    pub async fn load_volume(&mut self) -> toasty::Result<u8> {
        let val = self
            .load_app_setting("volume")
            .await?
            .unwrap_or_else(|| "100".to_string());
        Ok(val.parse().unwrap_or(100))
    }

    pub async fn save_audio_quality(&mut self, quality: AudioQuality) -> toasty::Result<()> {
        let val = serde_json::to_string(&quality).unwrap_or_else(|_| "\"Normal\"".to_string());
        self.save_app_setting("audio_quality", &val).await
    }

    pub async fn load_audio_quality(&mut self) -> toasty::Result<AudioQuality> {
        let val = self
            .load_app_setting("audio_quality")
            .await?
            .unwrap_or_default();
        Ok(serde_json::from_str(&val).unwrap_or_default())
    }

    pub async fn save_discord_rpc(&mut self, enabled: bool) -> toasty::Result<()> {
        self.save_app_setting("discord_rpc", &enabled.to_string())
            .await
    }

    pub async fn load_discord_rpc(&mut self) -> toasty::Result<bool> {
        let val = self
            .load_app_setting("discord_rpc")
            .await?
            .unwrap_or_default();
        Ok(val.parse().unwrap_or(false))
    }

    pub async fn save_custom_titlebar(&mut self, enabled: bool) -> toasty::Result<()> {
        self.save_app_setting("custom_titlebar", &enabled.to_string())
            .await
    }

    pub async fn load_custom_titlebar(&mut self) -> toasty::Result<bool> {
        let val = self
            .load_app_setting("custom_titlebar")
            .await?
            .unwrap_or_else(|| "true".to_string());
        Ok(val.parse().unwrap_or(true))
    }

    pub async fn save_auto_hide_navbar(&mut self, enabled: bool) -> toasty::Result<()> {
        self.save_app_setting("auto_hide_navbar", &enabled.to_string())
            .await
    }

    pub async fn load_auto_hide_navbar(&mut self) -> toasty::Result<bool> {
        let val = self
            .load_app_setting("auto_hide_navbar")
            .await?
            .unwrap_or_default();
        Ok(val.parse().unwrap_or(false))
    }

    async fn save_app_setting(&mut self, key: &str, value: &str) -> toasty::Result<()> {
        if let Ok(mut setting) = AppSetting::get_by_key(&mut self.db, key).await {
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
        if let Ok(setting) = AppSetting::get_by_key(&mut self.db, key).await {
            Ok(Some(setting.value))
        } else {
            Ok(None)
        }
    }
}
