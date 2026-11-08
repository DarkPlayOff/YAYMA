use super::*;

impl ApiService {
    pub async fn fetch_ugc_upload_info(&self, kind: u32, name: &str) -> Result<String> {
        let url = format!(
            "{API_RU}/loader/upload-url?uid={0}&playlist-id={0}:{1}&path={2}",
            self.user_id,
            kind,
            urlencoding::encode(name)
        );
        Ok(send_with_retry(|| self.http_client.post(&url))
            .await?
            .json::<serde_json::Value>()
            .await?["post-target"]
            .as_str()
            .ok_or("No target")?
            .to_string())
    }

    pub async fn upload_ugc_track(&self, url: &str, path: &str) -> Result<String> {
        let name = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("t.mp3");
        let form = reqwest::multipart::Form::new().part(
            "file",
            reqwest::multipart::Part::bytes(tokio::fs::read(path).await?)
                .file_name(name.to_string())
                .mime_str("audio/mpeg")?,
        );
        let v = self
            .http_client
            .post(url)
            .multipart(form)
            .send()
            .await?
            .json::<serde_json::Value>()
            .await?;
        let id = v["id"].as_str().map(|s| s.to_string()).unwrap_or_else(|| {
            if v["result"] == "CREATED" {
                "CREATED_PENDING".into()
            } else {
                v.to_string()
            }
        });
        Ok(id)
    }
}
