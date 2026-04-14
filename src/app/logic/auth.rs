use crate::api::models::{AppError, SavedStateDto, UserAccountDto};
use crate::app::{APP_DB, AppContext, CURRENT_SESSION, initialize_app};
use crate::auth::TokenProvider;
use crate::http::ApiService;
use std::sync::Arc;

pub async fn restore_saved_state(_ctx: &AppContext) -> Option<SavedStateDto> {
    let db = APP_DB.get()?.lock();
    db.load_playback_state().ok().flatten().map(|(id, pos, playing)| SavedStateDto {
        track_id: id,
        position_ms: pos as u32,
        is_playing: playing,
    })
}

pub async fn clear_token() {
    let _ = TokenProvider::delete();
    if let Some(session) = CURRENT_SESSION.swap(None) {
        session.stop();
    }
}

pub async fn login_with_token(token: String) -> Result<AppContext, AppError> {
    let (client, user_id) = TokenProvider::validate(token.clone()).await
        .map_err(|_| AppError::InvalidToken)?;

    let _ = TokenProvider::store(&token, user_id);
    
    let api = ApiService::new(token, Some(client), Some(user_id)).await
        .map_err(|e| AppError::ApiError(e.to_string()))?;

    let context = initialize_app(api).await
        .map_err(|e| AppError::Unknown(e.to_string()))?;

    Ok(Arc::try_unwrap(context).unwrap_or_else(|arc| (*arc).clone()))
}

pub async fn try_auto_login() -> Option<AppContext> {
    let (token, _) = TokenProvider::resolve()?;
    login_with_token(token).await.ok()
}

pub async fn get_account_info(ctx: &AppContext) -> Option<UserAccountDto> {
    ctx.api.get_account_info().await.ok()
}
