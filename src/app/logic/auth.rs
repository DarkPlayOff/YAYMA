use crate::api::models::{AppError, SavedStateDto, UserAccountDto};
use crate::app::{APP_DB, AppContext, initialize_app};
use crate::auth::TokenProvider;
use crate::http::ApiService;

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
}

pub async fn login_with_token(token: String) -> Result<AppContext, AppError> {
    let (client, user_id) = TokenProvider::validate(token.clone()).await
        .map_err(|_| AppError::InvalidToken)?;

    let _ = TokenProvider::store(&token, user_id);
    
    let api = ApiService::new(token, Some(client), Some(user_id)).await
        .map_err(|e| AppError::ApiError(e.to_string()))?;

    initialize_app(api).await
        .map_err(|e| AppError::Unknown(e.to_string()))
}

pub async fn try_auto_login() -> Option<AppContext> {
    let (token, _) = TokenProvider::resolve()?;
    login_with_token(token).await.ok()
}

pub async fn get_account_info(ctx: &AppContext) -> Option<UserAccountDto> {
    ctx.api.get_account_info().await.ok()
}
