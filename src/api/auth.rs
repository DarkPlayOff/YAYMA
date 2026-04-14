use crate::api::models::{AppError, SavedStateDto, UserAccountDto};
use crate::app::{AppContext, initialize_infrastructure};
use crate::app::logic::auth as logic;
use flutter_rust_bridge::frb;

#[frb(init)]
pub fn init_app() {
    initialize_infrastructure();
}

pub async fn restore_saved_state(ctx: &AppContext) -> Option<SavedStateDto> {
    logic::restore_saved_state(ctx).await
}

pub async fn clear_token() {
    logic::clear_token().await
}

pub async fn login_with_token(token: String) -> Result<AppContext, AppError> {
    logic::login_with_token(token).await
}

pub async fn try_auto_login() -> Option<AppContext> {
    logic::try_auto_login().await
}

#[frb]
pub async fn get_account_info(ctx: &AppContext) -> Option<UserAccountDto> {
    logic::get_account_info(ctx).await
}
