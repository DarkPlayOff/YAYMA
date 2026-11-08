use super::*;
use chrono::{SecondsFormat, Utc};

/// `POST /plays` identity: the desktop app's unversioned client id, unlike the
/// versioned one used for every other request.
const PLAYS_CLIENT_ID: &str = "YandexMusicDesktopApp";

impl ApiService {
    /// `POST /plays` — the reports behind the server-side playback history.
    /// Field set and identity mirror the desktop client (`changeReason` +
    /// `pause` carry the event kind, `clientNow` is ISO-8601).
    ///
    /// Endpoint quirks: no `x-yandex-music-device` header (it makes the server
    /// answer 400), and the unversioned [`PLAYS_CLIENT_ID`] rather than the
    /// versioned id used elsewhere. Whether a report is stored depends on the
    /// payload — see [`crate::audio::plays::PlayContext`].
    pub async fn send_plays(&self, plays: Vec<serde_json::Value>) -> Result<()> {
        let client_now = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        let response = send_with_retry(|| {
            self.http_client
                .post(format!("{API_RU}/plays"))
                .query(&[("clientNow", client_now.as_str())])
                .header("X-Yandex-Music-Client", PLAYS_CLIENT_ID)
                .json(&serde_json::json!({ "plays": plays }))
        })
        .await?;
        // A 200 with an error envelope is the silent "not recorded" case; log it.
        let body = response.text().await.unwrap_or_default();
        let result_is_ok = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .is_some_and(|value| value["result"] == "ok");
        if !result_is_ok {
            // Char-safe: a byte slice at 300 panics inside a multi-byte
            // character, and these bodies carry Russian error text.
            let preview: String = body.chars().take(300).collect();
            tracing::warn!(body = preview, "plays_response_unexpected");
        }
        Ok(())
    }
}
