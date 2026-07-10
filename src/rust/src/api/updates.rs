use crate::app::logic::updates as logic;

#[derive(Debug, Clone)]
pub struct AppUpdateInfoDto {
    pub latest_version: String,
    pub changelog: String,
    pub url: String,
    pub has_update: bool,
}

pub async fn check_for_updates() -> Option<AppUpdateInfoDto> {
    logic::check_for_updates().await
}
