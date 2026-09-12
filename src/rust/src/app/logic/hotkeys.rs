use crate::api::models::{HotkeyBindingDto, HotkeySettingsDto, HotkeyUpdateResultDto};
use crate::app::hotkeys::{self, HotkeyAction, HotkeyBinding, HotkeySettings};
use crate::app::AppContext;

fn to_dto(settings: &HotkeySettings) -> HotkeySettingsDto {
    HotkeySettingsDto {
        enabled: settings.enabled,
        bindings: settings
            .bindings
            .iter()
            .map(|b| HotkeyBindingDto {
                action: b.action.clone(),
                enabled: b.enabled,
                key: b.key.clone(),
                ctrl: b.ctrl,
                alt: b.alt,
                shift: b.shift,
                meta: b.meta,
            })
            .collect(),
    }
}

fn replace_binding(settings: &mut HotkeySettings, binding: HotkeyBinding) {
    if let Some(slot) = settings
        .bindings
        .iter_mut()
        .find(|b| b.action == binding.action)
    {
        *slot = binding;
    }
}

pub async fn get_hotkey_settings(ctx: &AppContext) -> HotkeySettingsDto {
    let _ = ctx;
    to_dto(&hotkeys::settings_snapshot())
}

pub async fn set_hotkeys_enabled(ctx: &AppContext, enabled: bool) -> HotkeySettingsDto {
    let mut settings = hotkeys::settings_snapshot();
    settings.enabled = enabled;
    hotkeys::apply_settings(ctx, settings).await;
    to_dto(&hotkeys::settings_snapshot())
}

/// Record a new combo for `action`. The key arrives as the captured Flutter
/// `PhysicalKeyboardKey.usbHidUsage` and is mapped to a `keyboard_types::Code`
/// here, so the UI never deals with platform key representations. Rejections
/// (unknown action, unmappable key, combo already taken) are reported as a
/// structured result instead of an error, so the UI can show a precise
/// message without string matching.
pub async fn set_hotkey_binding(
    ctx: &AppContext,
    action: String,
    usb_hid_usage: u64,
    ctrl: bool,
    alt: bool,
    shift: bool,
    meta: bool,
) -> HotkeyUpdateResultDto {
    let reject = |conflict_with: Option<String>, invalid_key: bool| HotkeyUpdateResultDto {
        settings: None,
        conflict_with,
        invalid_key,
    };

    let Some(action_id) = HotkeyAction::from_name(&action) else {
        return reject(None, true);
    };
    let Some(key) = hotkeys::key_from_usb_hid_usage(usb_hid_usage) else {
        return reject(None, true);
    };

    let mut settings = hotkeys::settings_snapshot();
    if let Some(conflict) = settings.bindings.iter().find(|b| {
        b.action != action && b.key == key && b.ctrl == ctrl && b.alt == alt && b.shift == shift
            && b.meta == meta
    }) {
        return reject(Some(conflict.action.clone()), false);
    }

    replace_binding(
        &mut settings,
        HotkeyBinding {
            action: action_id.name().to_string(),
            enabled: true,
            key,
            ctrl,
            alt,
            shift,
            meta,
        },
    );
    hotkeys::apply_settings(ctx, settings).await;
    HotkeyUpdateResultDto {
        settings: Some(to_dto(&hotkeys::settings_snapshot())),
        conflict_with: None,
        invalid_key: false,
    }
}

pub async fn set_hotkey_binding_enabled(
    ctx: &AppContext,
    action: String,
    enabled: bool,
) -> HotkeySettingsDto {
    let mut settings = hotkeys::settings_snapshot();
    if let Some(binding) = settings.bindings.iter_mut().find(|b| b.action == action) {
        binding.enabled = enabled;
    }
    hotkeys::apply_settings(ctx, settings).await;
    to_dto(&hotkeys::settings_snapshot())
}

pub async fn reset_hotkey_defaults(ctx: &AppContext) -> HotkeySettingsDto {
    let settings = hotkeys::default_settings_public();
    hotkeys::apply_settings(ctx, settings).await;
    to_dto(&hotkeys::settings_snapshot())
}

pub fn dispose_hotkeys(_ctx: &AppContext) {
    hotkeys::shutdown();
}
