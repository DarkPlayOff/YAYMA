#[derive(Debug, toasty::Model)]
pub struct TrackMetadataEntity {
    #[key]
    pub track_id: String,
    pub title: String,
    pub version: Option<String>,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub cover_url: Option<String>,
    pub duration_ms: u64,

    #[has_many]
    pub artists: toasty::Deferred<Vec<TrackMetadataArtist>>,
}

#[derive(Debug, toasty::Model)]
pub struct TrackMetadataArtist {
    #[key]
    pub id: String,

    #[index]
    pub track_metadata_entity_id: String,

    #[belongs_to(key = track_metadata_entity_id, references = track_id)]
    pub track_metadata_entity: toasty::Deferred<TrackMetadataEntity>,

    pub artist_id: String,
    pub name: String,
    pub position: i64,
}

#[derive(Debug, toasty::Model)]
pub struct CacheMetadata {
    #[key]
    pub url: String,
    pub file_path: String,
    pub size: u64,
    pub last_access_at: i64,
    pub created_at: i64,
    pub expires_at: i64,
    pub etag: Option<String>,
}

#[derive(Debug, toasty::Model)]
pub struct AppSetting {
    #[key]
    pub key: String,
    pub value: String,
}
