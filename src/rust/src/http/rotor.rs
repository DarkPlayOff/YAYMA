use super::*;
use chrono::Utc;
use std::sync::atomic::Ordering;
use yandex_music::api::rotor::send_station_feedback::SendStationFeedbackOptions;
use yandex_music::model::rotor::{
    Rotor,
    feedback::{StationFeedback, StationFeedbackEvent},
    session::Session,
};

impl ApiService {
    pub async fn fetch_stations(&self) -> Result<Vec<Rotor>> {
        let opts = yandex_music::api::rotor::get_all_stations::GetAllStationsOptions::default();
        Ok(self.client.get_all_stations(&opts).await?)
    }

    pub async fn create_session(&self, seeds: Vec<String>) -> Result<Session> {
        self.rotor_request(
            "rotor/session/new",
            serde_json::json!({
                "seeds": seeds,
                "queue": [],
                "includeTracksInResponse": true,
                "includeWaveModel": true,
                "interactive": true,
            }),
        )
        .await
    }

    pub async fn get_session_tracks(
        &self,
        session_id: String,
        queue: Vec<String>,
        feedbacks: Vec<StationFeedback>,
    ) -> Result<Session> {
        self.rotor_request(
            &format!("rotor/session/{session_id}/tracks"),
            serde_json::json!({ "queue": queue, "feedbacks": feedbacks }),
        )
        .await
    }

    /// Rotor session calls go through `http_client` directly (not the crate)
    /// because "Меньше ИИ" rides as a request header the crate's session
    /// options can't set. The header is absent in "standard" mode, exactly
    /// like the official client.
    async fn rotor_request(&self, path: &str, body: serde_json::Value) -> Result<Session> {
        let reduced = self.ai_reduction.load(Ordering::Relaxed);
        let url = format!("{}{path}", yandex_music::API_PATH);
        let response = send_with_retry(|| {
            let request = self.http_client.post(&url).json(&body);
            if reduced {
                request.header("X-Yandex-Music-AI-Content-Rate", "reduced")
            } else {
                request
            }
        })
        .await?;
        let body: serde_json::Value = response.json().await?;
        if let Some(error) = body.get("error") {
            return Err(format!("rotor error: {error}").into());
        }
        Ok(serde_json::from_value(
            body.get("result")
                .cloned()
                .ok_or("rotor response has no result")?,
        )?)
    }

    pub async fn send_rotor_feedback(
        &self,
        station_id: String,
        batch_id: Option<String>,
        feedback_type: &str,
        track_id: Option<String>,
        from: Option<String>,
        total_played: Option<Duration>,
    ) -> Result<()> {
        let event = StationFeedbackEvent {
            item_type: Some(feedback_type.to_string()),
            timestamp: Utc::now(),
            from: None,
            track_id,
            total_played,
            track_length: None,
        };
        let feedback = StationFeedback {
            batch_id,
            event,
            from,
        };

        let opts = SendStationFeedbackOptions::new(station_id, feedback);
        self.client.send_station_feedback(&opts).await?;

        Ok(())
    }
}
