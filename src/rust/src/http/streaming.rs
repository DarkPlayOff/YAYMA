use super::*;
use crate::api::models::AudioQuality;
use yandex_music::api::track::{
    get_file_info::GetFileInfoOptions, get_file_info_batch::GetFileInfoBatchOptions,
    get_tracks::GetTracksOptions,
};
use yandex_music::model::{
    info::file_info::{Codec, Quality, TrackFileInfo},
    track::Track,
};

impl ApiService {
    pub async fn fetch_tracks(&self, track_ids: Vec<String>) -> Result<Vec<Track>> {
        let opts = GetTracksOptions::new(track_ids);
        Ok(self.client.get_tracks(&opts).await?)
    }

    pub async fn fetch_file_info_batch(
        &self,
        track_ids: Vec<String>,
        quality: Quality,
    ) -> Result<Vec<TrackFileInfo>> {
        let opts = GetFileInfoBatchOptions::new(track_ids).quality(quality);
        retry_client_call(|| self.file_info_client.get_file_info_batch(&opts)).await
    }

    fn map_quality(quality: AudioQuality) -> Quality {
        match quality {
            AudioQuality::High => Quality::Lossless,
            AudioQuality::Normal => Quality::Normal,
            AudioQuality::Low => Quality::Low,
        }
    }

    fn codec_by_name(name: &str) -> Option<Codec> {
        Codec::all().into_iter().find(|c| c.to_string() == name)
    }

    async fn fetch_track_url_with_codec(
        &self,
        track_id: String,
        quality: AudioQuality,
        preferred_codec: Option<&str>,
    ) -> Result<(String, String)> {
        let mut opts = GetFileInfoOptions::new(track_id).quality(Self::map_quality(quality));
        if let Some(codec) = preferred_codec.and_then(Self::codec_by_name) {
            opts = opts.codecs([codec]);
        }

        let info = retry_client_call(|| self.file_info_client.get_file_info(&opts)).await?;
        Ok((info.url, info.codec))
    }

    pub async fn fetch_track_stream_info(&self, track_id: String) -> Result<TrackStreamInfo> {
        let opts = GetFileInfoOptions::new(track_id).quality(Self::map_quality(self.get_quality()));
        let info = retry_client_call(|| self.file_info_client.get_file_info(&opts)).await?;
        let mirror_urls = info
            .urls
            .iter()
            .filter(|u| *u != &info.url)
            .cloned()
            .collect();
        Ok(TrackStreamInfo {
            url: info.url,
            mirror_urls,
            codec: info.codec,
        })
    }

    pub async fn fetch_track_url(&self, track_id: String) -> Result<(String, String)> {
        self.fetch_track_url_with_codec(track_id, self.get_quality(), None)
            .await
    }

    pub async fn fetch_track_url_for_download(&self, track_id: String) -> Result<(String, String)> {
        // Try the same fetch as playback first (favors FLAC for Lossless quality)
        let (url, codec) = self.fetch_track_url(track_id.clone()).await?;

        // If it's already FLAC or MP3, we are happy.
        if codec.contains("flac") || codec.contains("mp3") {
            return Ok((url, codec));
        }

        // If it's AAC, we try to force MP3 instead because raw AAC doesn't support tags well.
        let quality = self.get_quality();
        if let Ok(res) = self
            .fetch_track_url_with_codec(track_id, quality, Some("mp3"))
            .await
        {
            return Ok(res);
        }

        Ok((url, codec))
    }

    pub async fn fetch_track_urls_batch(
        &self,
        track_ids: Vec<String>,
    ) -> Result<Vec<(String, String, Vec<String>, String)>> {
        let quality = self.get_quality();

        let infos = self
            .fetch_file_info_batch(track_ids.clone(), Self::map_quality(quality))
            .await?;

        if infos.len() != track_ids.len() {
            return Err(Box::from(format!(
                "get-file-info/batch returned {} results for {} requested tracks",
                infos.len(),
                track_ids.len()
            )));
        }

        Ok(track_ids
            .into_iter()
            .zip(infos)
            .map(|(track_id, info)| {
                let mirror_urls = info
                    .urls
                    .iter()
                    .filter(|url| *url != &info.url)
                    .cloned()
                    .collect();
                (track_id, info.url, mirror_urls, info.codec)
            })
            .collect())
    }
}
