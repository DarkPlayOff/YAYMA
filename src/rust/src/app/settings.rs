use crate::app::AppContext;
use crate::audio::commands::AudioMessage;
use std::collections::HashMap;

fn parse_setting<T: serde::de::DeserializeOwned>(
    settings: &HashMap<String, String>,
    key: &str,
) -> Option<T> {
    settings
        .get(key)
        .and_then(|value| serde_json::from_str(value).ok())
}

pub async fn load_persisted_settings(ctx: &AppContext) {
    let settings = {
        let mut db = ctx.core.db.lock().await;
        db.load_all_settings().await.unwrap_or_default()
    };

    #[cfg(target_os = "android")]
    {
        // TODO: remove this. Temporary fix for users stuck with a low persisted
        // volume from an old ducking bug — on Android there's no in-app slider to
        // recover. Force the in-app volume to 100% on every launch and heal the
        // stored value, then delete the cfg block once the bad value is flushed.
        let mut db = ctx.core.db.lock().await;
        let _ = db.save_setting("volume", &100u8).await;
        let _ = ctx.audio.tx.send(AudioMessage::SetVolume(100)).await;
    }

    #[cfg(not(target_os = "android"))]
    {
        let volume = parse_setting::<u8>(&settings, "volume").or(Some(100));

        if let Some(volume) = volume {
            let _ = ctx.audio.tx.send(AudioMessage::SetVolume(volume)).await;
        }
    }

    if let Some(quality) =
        parse_setting::<crate::api::models::AudioQuality>(&settings, "audio_quality")
    {
        ctx.core.api.set_quality(quality);
    }

    if let Some(rpc_enabled) = parse_setting::<bool>(&settings, "discord_rpc") {
        ctx.audio.signals.discord_rpc.set(rpc_enabled);
    }

    if let Some(device) = parse_setting::<String>(&settings, "audio_device")
        && !device.is_empty()
    {
        ctx.audio.signals.selected_device.set(Some(device));
        let _ = ctx.audio.tx.send(AudioMessage::RecreateStream).await;
    }

    let (eq_info, other_effects) = {
        let guard = ctx.audio.effect_handles.read();

        let eq_info = guard.get("eq").map(|_eq| true);

        let mut others = Vec::new();
        for id in guard.keys() {
            if matches!(id.as_str(), "eq" | "monitor" | "fade") {
                continue;
            }
            others.push(id.clone());
        }

        (eq_info, others)
    };

    if eq_info.is_some()
        && let Some((enabled, bands)) = parse_setting::<(bool, Vec<f32>)>(&settings, "equalizer")
    {
        let guard = ctx.audio.effect_handles.read();
        if let Some(eq) = guard.get("eq") {
            eq.set_enabled(enabled);
            for (i, &gain) in bands.iter().enumerate() {
                eq.set_param(i, gain);
            }
        }
    }

    for id in other_effects {
        if let Some((enabled, params)) =
            parse_setting::<(bool, Vec<f32>)>(&settings, &format!("effect_{id}"))
        {
            let guard = ctx.audio.effect_handles.read();
            if let Some(handle) = guard.get(&id) {
                handle.set_enabled(enabled);
                for (i, &val) in params.iter().enumerate() {
                    handle.set_param(i, val);
                }
            }
        }
    }
}
