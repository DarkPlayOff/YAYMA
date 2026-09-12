use crate::api::models::{HotkeySettingsDto, HotkeyUpdateResultDto};
use crate::app::logic::hotkeys as logic;

pub async fn get_hotkey_settings(ctx: &crate::api::AppContext) -> HotkeySettingsDto {
    logic::get_hotkey_settings(ctx).await
}

pub async fn set_hotkeys_enabled(ctx: &crate::api::AppContext, enabled: bool) -> HotkeySettingsDto {
    logic::set_hotkeys_enabled(ctx, enabled).await
}

#[allow(clippy::too_many_arguments)]
pub async fn set_hotkey_binding(
    ctx: &crate::api::AppContext,
    action: String,
    usb_hid_usage: u64,
    ctrl: bool,
    alt: bool,
    shift: bool,
    meta: bool,
) -> HotkeyUpdateResultDto {
    logic::set_hotkey_binding(ctx, action, usb_hid_usage, ctrl, alt, shift, meta).await
}

pub async fn set_hotkey_binding_enabled(
    ctx: &crate::api::AppContext,
    action: String,
    enabled: bool,
) -> HotkeySettingsDto {
    logic::set_hotkey_binding_enabled(ctx, action, enabled).await
}

pub async fn reset_hotkey_defaults(ctx: &crate::api::AppContext) -> HotkeySettingsDto {
    logic::reset_hotkey_defaults(ctx).await
}

pub fn dispose_hotkeys(ctx: &crate::api::AppContext) {
    logic::dispose_hotkeys(ctx)
}
