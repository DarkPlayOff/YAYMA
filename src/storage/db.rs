use chrono;
use directories::ProjectDirs;
use rusqlite::{Connection, Result, params};
use std::path::PathBuf;

/// Default TTL for cached images: 7 days in seconds
const DEFAULT_CACHE_TTL_SECS: i64 = 7 * 24 * 60 * 60;

pub struct AppDatabase {
    conn: Connection,
}

impl AppDatabase {
    pub fn init() -> Result<Self> {
        let db_path = if let Some(proj_dirs) = ProjectDirs::from("com", "yamusic", "yamusic") {
            let data_dir = proj_dirs.data_dir();
            std::fs::create_dir_all(data_dir).ok();
            data_dir.join("yamusic.db")
        } else {
            PathBuf::from("yamusic.db")
        };

        let conn = Connection::open(db_path)?;

        // Performance optimizations
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "cache_size", -30000)?; // ~30MB cache
        conn.pragma_update(None, "temp_store", "MEMORY")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;

        let migrations = [
            "CREATE TABLE IF NOT EXISTS playback_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                track_id TEXT NOT NULL,
                position_ms INTEGER NOT NULL,
                is_playing INTEGER NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS download_path (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                path TEXT NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS liked_tracks (
                track_id TEXT PRIMARY KEY
            )",
            "CREATE TABLE IF NOT EXISTS track_metadata (
                track_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                version TEXT,
                artists TEXT NOT NULL,
                album TEXT,
                album_id TEXT,
                cover_url TEXT,
                duration_ms INTEGER NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS equalizer_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                enabled INTEGER NOT NULL DEFAULT 0,
                bands TEXT NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS effect_settings (
                effect_id TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 0,
                params TEXT NOT NULL
            )",
            "CREATE TABLE IF NOT EXISTS cache_metadata (
                url TEXT PRIMARY KEY,
                file_path TEXT NOT NULL,
                size INTEGER NOT NULL,
                last_access_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL DEFAULT 0,
                etag TEXT
            )",
            "CREATE TABLE IF NOT EXISTS app_settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )",
            "CREATE INDEX IF NOT EXISTS idx_cache_last_access ON cache_metadata(last_access_at)",
            "CREATE INDEX IF NOT EXISTS idx_cache_expires_at ON cache_metadata(expires_at)",
            "CREATE INDEX IF NOT EXISTS idx_liked_track_id ON liked_tracks(track_id)",
            "CREATE INDEX IF NOT EXISTS idx_metadata_track_id ON track_metadata(track_id)",
            "CREATE INDEX IF NOT EXISTS idx_metadata_search ON track_metadata(title, artists)",
        ];

        for m in migrations {
            conn.execute(m, [])?;
        }

        // Apply column additions gracefully
        let _ = conn.execute(
            "ALTER TABLE cache_metadata ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0",
            [],
        );
        let _ = conn.execute(
            "UPDATE cache_metadata SET expires_at = created_at + 604800 WHERE expires_at = 0",
            [],
        );

        Ok(Self { conn })
    }

    pub fn update_cache_metadata(
        &self,
        url: &str,
        file_path: &str,
        size: u64,
        etag: Option<&str>,
    ) -> Result<()> {
        let now = chrono::Utc::now().timestamp();
        let expires_at = now + DEFAULT_CACHE_TTL_SECS;
        self.conn.execute(
            "INSERT INTO cache_metadata (url, file_path, size, last_access_at, created_at, expires_at, etag)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(url) DO UPDATE SET
             last_access_at = excluded.last_access_at,
             size = excluded.size,
             etag = excluded.etag,
             expires_at = excluded.expires_at",
            params![url, file_path, size as i64, now, now, expires_at, etag],
        )?;
        Ok(())
    }

    /// Returns (file_path, etag, is_expired).
    /// If expired, caller should re-download and the TTL will be renewed on save.
    pub fn get_cache_metadata(&self, url: &str) -> Result<Option<(String, Option<String>, bool)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT file_path, etag, expires_at FROM cache_metadata WHERE url = ?1")?;
        let mut rows = stmt.query(params![url])?;

        if let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            let etag: Option<String> = row.get(1)?;
            let expires_at: i64 = row.get(2)?;

            let now = chrono::Utc::now().timestamp();
            let is_expired = now >= expires_at;

            // Update last access time and renew TTL if still valid
            if !is_expired {
                let new_expires = now + DEFAULT_CACHE_TTL_SECS;
                let _ = self.conn.execute(
                    "UPDATE cache_metadata SET last_access_at = ?1, expires_at = ?2 WHERE url = ?3",
                    params![now, new_expires, url],
                );
            }

            Ok(Some((path, etag, is_expired)))
        } else {
            Ok(None)
        }
    }

    /// Delete all entries that have expired. Returns list of file paths to delete.
    /// Gracefully handles missing table (before migration).
    pub fn prune_expired(&self) -> Result<Vec<String>> {
        let now = chrono::Utc::now().timestamp();
        let mut stmt = match self
            .conn
            .prepare("SELECT file_path FROM cache_metadata WHERE expires_at <= ?1")
        {
            Ok(s) => s,
            Err(_) => return Ok(vec![]), // Table might not exist yet
        };
        let rows = stmt.query_map(params![now], |r| r.get(0))?;
        let mut paths = Vec::new();
        for p in rows {
            paths.push(p?);
        }
        let _ = self.conn.execute(
            "DELETE FROM cache_metadata WHERE expires_at <= ?1",
            params![now],
        );
        Ok(paths)
    }

    pub fn prune_cache(&self, max_size_bytes: i64) -> Result<Vec<String>> {
        let current_size: i64 = self.conn.query_row(
            "SELECT COALESCE(SUM(size), 0) FROM cache_metadata",
            [],
            |r| r.get(0),
        )?;

        if current_size <= max_size_bytes {
            return Ok(vec![]);
        }

        let target_size = (max_size_bytes as f64 * 0.8) as i64;
        let mut to_delete = Vec::new();
        let mut deleted_size = 0i64;

        let mut stmt = self.conn.prepare(
            "SELECT url, file_path, size FROM cache_metadata ORDER BY last_access_at ASC",
        )?;
        let mut rows = stmt.query([])?;

        while let Some(row) = rows.next()? {
            if current_size - deleted_size <= target_size {
                break;
            }
            let _url: String = row.get(0)?;
            let path: String = row.get(1)?;
            let size: i64 = row.get(2)?;

            to_delete.push(path);
            deleted_size += size;
        }

        // Batch delete from DB
        for path in &to_delete {
            let _ = self.conn.execute(
                "DELETE FROM cache_metadata WHERE file_path = ?1",
                params![path],
            );
        }

        Ok(to_delete)
    }

    pub fn save_playback_state(
        &self,
        track_id: &str,
        position_ms: u64,
        is_playing: bool,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO playback_state (id, track_id, position_ms, is_playing)
             VALUES (1, ?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET
             track_id = excluded.track_id,
             position_ms = excluded.position_ms,
             is_playing = excluded.is_playing",
            params![track_id, position_ms as i64, if is_playing { 1 } else { 0 }],
        )?;
        Ok(())
    }

    pub fn load_playback_state(&self) -> Result<Option<(String, u64, bool)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT track_id, position_ms, is_playing FROM playback_state WHERE id = 1")?;
        let mut rows = stmt.query([])?;

        if let Some(row) = rows.next()? {
            let track_id: String = row.get(0)?;
            let position_ms: i64 = row.get(1)?;
            let is_playing: i32 = row.get(2)?;
            Ok(Some((track_id, position_ms as u64, is_playing != 0)))
        } else {
            Ok(None)
        }
    }

    pub fn save_download_path(&self, path: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO download_path (id, path)
             VALUES (1, ?1)
             ON CONFLICT(id) DO UPDATE SET path = excluded.path",
            params![path],
        )?;
        Ok(())
    }

    pub fn load_download_path(&self) -> Result<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path FROM download_path WHERE id = 1")?;
        let mut rows = stmt.query([])?;

        if let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            Ok(Some(path))
        } else {
            Ok(None)
        }
    }

    pub fn save_liked_tracks(&self, track_ids: &[String]) -> Result<()> {
        self.conn.execute("BEGIN TRANSACTION", [])?;
        let result = (|| {
            self.conn.execute("DELETE FROM liked_tracks", [])?;
            let mut stmt = self
                .conn
                .prepare("INSERT INTO liked_tracks (track_id) VALUES (?1)")?;
            for id in track_ids {
                stmt.execute(params![id])?;
            }
            Ok(())
        })();

        if result.is_ok() {
            self.conn.execute("COMMIT TRANSACTION", [])?;
        } else {
            self.conn.execute("ROLLBACK TRANSACTION", [])?;
        }
        result
    }

    pub fn load_liked_tracks(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare("SELECT track_id FROM liked_tracks")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        let mut result = Vec::new();
        for id in rows {
            result.push(id?);
        }
        Ok(result)
    }

    pub fn add_liked_track(&self, track_id: &str) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO liked_tracks (track_id) VALUES (?1)",
            params![track_id],
        )?;
        Ok(())
    }

    pub fn remove_liked_track(&self, track_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM liked_tracks WHERE track_id = ?1",
            params![track_id],
        )?;
        Ok(())
    }

    pub fn upsert_track_metadata(
        &self,
        id: &str,
        title: &str,
        version: Option<&str>,
        artists: &[String],
        album: Option<&str>,
        album_id: Option<&str>,
        cover_url: Option<&str>,
        duration_ms: u64,
    ) -> Result<()> {
        let artists_str = artists.join("|");
        self.conn.execute(
            "INSERT INTO track_metadata (track_id, title, version, artists, album, album_id, cover_url, duration_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(track_id) DO UPDATE SET
             title = excluded.title,
             version = excluded.version,
             artists = excluded.artists,
             album = excluded.album,
             album_id = excluded.album_id,
             cover_url = excluded.cover_url,
             duration_ms = excluded.duration_ms",
            params![
                id,
                title,
                version,
                artists_str,
                album,
                album_id,
                cover_url,
                duration_ms as i64
            ],
        )?;
        Ok(())
    }

    pub fn get_track_metadata(
        &self,
        track_ids: &[String],
    ) -> Result<
        Vec<(
            String,
            String,
            Option<String>,
            Vec<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            u64,
        )>,
    > {
        let mut result = Vec::new();
        let mut stmt = self.conn.prepare(
            "SELECT track_id, title, version, artists, album, album_id, cover_url, duration_ms 
             FROM track_metadata WHERE track_id = ?1",
        )?;

        for id in track_ids {
            let mut rows = stmt.query(params![id])?;
            if let Some(row) = rows.next()? {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let version: Option<String> = row.get(2)?;
                let artists_str: String = row.get(3)?;
                let album: Option<String> = row.get(4)?;
                let album_id: Option<String> = row.get(5)?;
                let cover_url: Option<String> = row.get(6)?;
                let duration_ms: i64 = row.get(7)?;

                let artists: Vec<String> = artists_str.split('|').map(|s| s.to_string()).collect();
                result.push((
                    track_id,
                    title,
                    version,
                    artists,
                    album,
                    album_id,
                    cover_url,
                    duration_ms as u64,
                ));
            }
        }
        Ok(result)
    }

    pub fn search_liked_tracks(&self, query: &str) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT lt.track_id 
             FROM liked_tracks lt
             JOIN track_metadata tm ON lt.track_id = tm.track_id
             WHERE tm.title LIKE ?1 OR tm.artists LIKE ?1",
        )?;

        let search_pattern = format!("%{}%", query);
        let rows = stmt.query_map(params![search_pattern], |row| row.get(0))?;

        let mut result = Vec::new();
        for id in rows {
            result.push(id?);
        }
        Ok(result)
    }

    pub fn save_equalizer(&self, enabled: bool, bands: &[f32]) -> Result<()> {
        let bands_json = serde_json::to_string(bands).unwrap_or_else(|_| "[]".to_string());
        self.conn.execute(
            "INSERT INTO equalizer_settings (id, enabled, bands)
             VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET
             enabled = excluded.enabled,
             bands = excluded.bands",
            params![if enabled { 1 } else { 0 }, bands_json],
        )?;
        Ok(())
    }

    pub fn load_equalizer(&self) -> Result<Option<(bool, Vec<f32>)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT enabled, bands FROM equalizer_settings WHERE id = 1")?;
        let mut rows = stmt.query([])?;

        if let Some(row) = rows.next()? {
            let enabled: i32 = row.get(0)?;
            let bands_json: String = row.get(1)?;
            let bands: Vec<f32> = serde_json::from_str(&bands_json).unwrap_or_default();
            Ok(Some((enabled != 0, bands)))
        } else {
            Ok(None)
        }
    }

    pub fn save_effect(&self, id: &str, enabled: bool, params: &[f32]) -> Result<()> {
        let params_json = serde_json::to_string(params).unwrap_or_else(|_| "[]".to_string());
        self.conn.execute(
            "INSERT INTO effect_settings (effect_id, enabled, params)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(effect_id) DO UPDATE SET
             enabled = excluded.enabled,
             params = excluded.params",
            params![id, if enabled { 1 } else { 0 }, params_json],
        )?;
        Ok(())
    }

    pub fn load_effect(&self, id: &str) -> Result<Option<(bool, Vec<f32>)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT enabled, params FROM effect_settings WHERE effect_id = ?1")?;
        let mut rows = stmt.query(params![id])?;

        if let Some(row) = rows.next()? {
            let enabled: i32 = row.get(0)?;
            let params_json: String = row.get(1)?;
            let params: Vec<f32> = serde_json::from_str(&params_json).unwrap_or_default();
            Ok(Some((enabled != 0, params)))
        } else {
            Ok(None)
        }
    }

    pub fn save_volume(&self, volume: u8) -> Result<()> {
        self.conn.execute("INSERT INTO app_settings (key, value) VALUES ('volume', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value", params![volume.to_string()])?;
        Ok(())
    }

    pub fn load_volume(&self) -> Result<u8> {
        let mut stmt = self
            .conn
            .prepare("SELECT value FROM app_settings WHERE key = 'volume'")?;
        let mut rows = stmt.query([])?;
        if let Some(row) = rows.next()? {
            let val: String = row.get(0)?;
            Ok(val.parse().unwrap_or(100))
        } else {
            Ok(100)
        }
    }

    pub fn save_audio_quality(&self, quality: crate::api::models::AudioQuality) -> Result<()> {
        let val = serde_json::to_string(&quality).unwrap_or_else(|_| "\"Normal\"".to_string());
        self.conn.execute(
            "INSERT INTO app_settings (key, value) VALUES ('audio_quality', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![val],
        )?;
        Ok(())
    }

    pub fn load_audio_quality(&self) -> Result<crate::api::models::AudioQuality> {
        let mut stmt = self
            .conn
            .prepare("SELECT value FROM app_settings WHERE key = 'audio_quality'")?;
        let mut rows = stmt.query([])?;
        if let Some(row) = rows.next()? {
            let val: String = row.get(0)?;
            Ok(serde_json::from_str(&val).unwrap_or_default())
        } else {
            Ok(crate::api::models::AudioQuality::default())
        }
    }
}
