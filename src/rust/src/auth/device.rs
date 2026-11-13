//! Yandex OAuth device flow (`oauth.yandex.ru`).
//!
//! The Dart login dialog only renders state; all HTTP and JSON handling lives
//! here so the widget performs no network calls of its own.

use std::time::Duration;

use serde::Deserialize;

use crate::api::auth::{DeviceCodeDto, DeviceTokenDto};
use crate::api::models::AppError;

const DEVICE_CODE_URL: &str = "https://oauth.yandex.ru/device/code";
const TOKEN_URL: &str = "https://oauth.yandex.ru/token";
const CLIENT_ID: &str = "23cabbbdc6cd418abb4b39c32c41195d";
const CLIENT_SECRET: &str = "53bc75238f0c4d08a118e51fe9203300";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Deserialize)]
struct TokenResponse {
    access_token: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

fn client() -> Result<reqwest::Client, AppError> {
    crate::util::tls::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|e| AppError::Unknown(e.to_string()))
}

pub async fn request_device_code() -> Result<DeviceCodeDto, AppError> {
    let response = client()?
        .post(DEVICE_CODE_URL)
        .form(&[("client_id", CLIENT_ID)])
        .send()
        .await
        .map_err(|_| AppError::NetworkError)?;

    let status = response.status();
    let body = response.text().await.map_err(|_| AppError::NetworkError)?;
    parse_device_code(status.is_success(), &body)
}

pub async fn poll_token(device_code: &str) -> Result<DeviceTokenDto, AppError> {
    let response = client()?
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "device_code"),
            ("client_id", CLIENT_ID),
            ("client_secret", CLIENT_SECRET),
            ("code", device_code),
        ])
        .send()
        .await
        .map_err(|_| AppError::NetworkError)?;

    let status = response.status();
    let body = response.text().await.map_err(|_| AppError::NetworkError)?;
    parse_token(status.is_success(), &body)
}

fn parse_device_code(success: bool, body: &str) -> Result<DeviceCodeDto, AppError> {
    if !success {
        return Err(AppError::ApiError(format!("HTTP device code: {body}")));
    }
    serde_json::from_str::<DeviceCodeDto>(body)
        .map_err(|e| AppError::ApiError(format!("invalid device code response: {e}")))
}

fn parse_token(success: bool, body: &str) -> Result<DeviceTokenDto, AppError> {
    let response: TokenResponse = serde_json::from_str(body)
        .map_err(|e| AppError::ApiError(format!("invalid token response: {e}")))?;

    // Pending is normal while the user has not confirmed the code yet: the
    // token DTO reports it as "no token, no error".
    if success || response.error.as_deref() == Some("authorization_pending") {
        return Ok(DeviceTokenDto {
            access_token: response.access_token,
            error: None,
        });
    }

    let message = response
        .error_description
        .or_else(|| {
            response
                .error
                .map(|error| format!("Ошибка авторизации ({error})."))
        })
        .unwrap_or_else(|| "Ошибка авторизации.".to_string());
    Ok(DeviceTokenDto {
        access_token: None,
        error: Some(message),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_code_parses() {
        let code = parse_device_code(
            true,
            r#"{"user_code":"ABCD","device_code":"dc","verification_url":"https://ya.ru/device","interval":5}"#,
        )
        .unwrap();
        assert_eq!(code.user_code, "ABCD");
        assert_eq!(code.device_code, "dc");
        assert_eq!(code.interval, 5);
    }

    #[test]
    fn device_code_interval_defaults() {
        let code = parse_device_code(
            true,
            r#"{"user_code":"ABCD","device_code":"dc","verification_url":"https://ya.ru/device"}"#,
        )
        .unwrap();
        assert_eq!(code.interval, 5);
    }

    #[test]
    fn token_received() {
        assert_eq!(
            parse_token(true, r#"{"access_token":"secret"}"#).unwrap(),
            DeviceTokenDto {
                access_token: Some("secret".to_string()),
                error: None,
            }
        );
    }

    #[test]
    fn token_pending() {
        assert_eq!(
            parse_token(false, r#"{"error":"authorization_pending"}"#).unwrap(),
            DeviceTokenDto {
                access_token: None,
                error: None,
            }
        );
    }

    #[test]
    fn token_rejected_uses_description() {
        assert_eq!(
            parse_token(
                false,
                r#"{"error":"invalid_grant","error_description":"Code expired"}"#,
            )
            .unwrap(),
            DeviceTokenDto {
                access_token: None,
                error: Some("Code expired".to_string()),
            }
        );
    }

    #[test]
    fn token_rejected_falls_back_to_error() {
        assert_eq!(
            parse_token(false, r#"{"error":"invalid_grant"}"#).unwrap(),
            DeviceTokenDto {
                access_token: None,
                error: Some("Ошибка авторизации (invalid_grant).".to_string()),
            }
        );
    }
}
