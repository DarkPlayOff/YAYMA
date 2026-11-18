use super::*;
use std::sync::atomic::Ordering;

impl ApiService {
    /// Enables/disables "Меньше ИИ" for subsequently created rotor sessions.
    pub fn set_ai_reduction(&self, enabled: bool) {
        self.ai_reduction.store(enabled, Ordering::Relaxed);
    }

    /// Mirrors the "Меньше ИИ" preference to the account, like the official
    /// clients do, so other clients see the same value. The rotor header below
    /// is what actually changes the recommendations.
    pub async fn set_ai_reduction_remote(&self, enabled: bool) -> Result<()> {
        let url = format!(
            "{}account/settings?aiContentReductionEnabled={enabled}",
            yandex_music::API_PATH
        );
        send_with_retry(|| self.http_client.post(&url).json(&serde_json::json!({}))).await?;
        Ok(())
    }

    /// Reads "Меньше ИИ" from the account settings, where the official
    /// clients keep it.
    pub async fn get_ai_reduction_remote(&self) -> Result<bool> {
        let url = format!("{}account/settings", yandex_music::API_PATH);
        let response = send_with_retry(|| self.http_client.get(&url)).await?;
        let body: serde_json::Value = response.json().await?;
        parse_ai_reduction(&body)
    }

    pub fn current_user_id(&self) -> u64 {
        self.user_id
    }

    /// One cheap account-status probe used to confirm a reported 401 before
    /// the UI logs out. Returns `false` only when the probe *also* got a 401
    /// from the auth host; network or server errors mean "cannot confirm"
    /// and keep the session, like the official desktop client's
    /// "confirmed-401" check.
    pub async fn verify_auth(&self) -> bool {
        self.client
            .get_account_status()
            .await
            .map(|_| true)
            .unwrap_or_else(|e| {
                !matches!(
                    crate::api::models::AppError::from(e),
                    crate::api::models::AppError::Unauthorized
                )
            })
    }

    pub async fn get_account_info(&self) -> Result<crate::api::models::UserAccountDto> {
        let status = self.client.get_account_status().await?;

        let mut avatar_url = None;
        if let Ok(resp) = self
            .client
            .inner
            .get(format!("{API_NET}/account/about"))
            .send()
            .await
            && let Ok(json) = resp.json::<serde_json::Value>().await
            && let Some(id) = json["result"]["avatarId"].as_str()
        {
            avatar_url = Some(format!(
                "https://avatars.mds.yandex.net/get-yapic/{}/islands-200",
                id
            ));
        }

        Ok(crate::api::models::UserAccountDto::from_yandex(
            status, avatar_url,
        ))
    }
}
