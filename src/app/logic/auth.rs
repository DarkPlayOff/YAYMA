use crate::api::models::{AppError, SavedStateDto, UserAccountDto};
use crate::app::{AppContext, initialize_app};
use crate::auth::TokenProvider;
use crate::http::ApiService;

pub async fn restore_saved_state(ctx: &AppContext) -> Option<SavedStateDto> {
    let mut db = ctx.core.db.lock().await;
    db.load_playback_state()
        .await
        .ok()
        .flatten()
        .map(|(id, pos, playing)| SavedStateDto {
            track_id: id,
            position_ms: pos as u32,
            is_playing: playing,
        })
}

pub async fn clear_token() {
    let _ = TokenProvider::delete();
}

pub async fn login_with_token(token: String) -> Result<AppContext, AppError> {
    let (client, user_id) = TokenProvider::validate(token.clone())
        .await
        .map_err(|_| AppError::InvalidToken)?;

    let _ = TokenProvider::store(&token, user_id);

    let api = ApiService::new(token, Some(client), Some(user_id))
        .await
        .map_err(|e| AppError::ApiError(e.to_string()))?;

    initialize_app(api)
        .await
        .map_err(|e| AppError::Unknown(e.to_string()))
}

pub async fn try_auto_login() -> Option<AppContext> {
    let (token, user_id) = TokenProvider::resolve()?;

    // Fast path: bypass token validation on auto-login to speed up startup.
    // We must initialize the Yandex client with the builder so it receives the token.
    if let Ok(client) = yandex_music::YandexMusicClient::builder(&token).build()
        && let Ok(api) = ApiService::new(
            token.clone(),
            Some(std::sync::Arc::new(client)),
            Some(user_id),
        )
        .await
            && let Ok(ctx) = initialize_app(api).await {
                return Some(ctx);
            }

    // Fallback if the fast path fails for any reason
    login_with_token(token).await.ok()
}

pub async fn get_account_info(ctx: &AppContext) -> Option<UserAccountDto> {
    ctx.core.api.get_account_info().await.ok()
}
