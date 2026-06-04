use crate::app::AppContext;
use crate::audio::commands::AudioMessage;

pub async fn load_persisted_settings(ctx: &AppContext) {
    let volume = {
        let mut db = ctx.core.db.lock().await;
        db.load_setting::<u8>("volume").await.unwrap_or(Some(100))
    };

    if let Some(volume) = volume {
        let _ = ctx.audio.tx.send(AudioMessage::SetVolume(volume)).await;
    }

    if let Ok(Some(quality)) = ctx.core.db.lock().await.load_setting::<crate::api::models::AudioQuality>("audio_quality").await {
        ctx.core.api.set_quality(quality);
    }

    if let Ok(Some(rpc_enabled)) = ctx.core.db.lock().await.load_setting::<bool>("discord_rpc").await {
        ctx.audio.signals.discord_rpc.set(rpc_enabled);
    }

    if let Ok(Some(device)) = ctx.core.db.lock().await.load_setting::<String>("audio_device").await {
        if !device.is_empty() {
            ctx.audio.signals.selected_device.set(Some(device));
            let _ = ctx.audio.tx.send(AudioMessage::RecreateStream).await;
        }
    }

    // Extract required data while holding the synchronous read lock to avoid keeping it across await points
    let (eq_info, other_effects) = {
        let guard = ctx.audio.effect_handles.read();

        let eq_info = guard.get("eq").map(|_eq| {
            // Need to save whether the equalizer logic should apply, but we get values later.
            // Actually, we just need to know if it exists.
            true
        });

        let mut others = Vec::new();
        for (id, _handle) in guard.iter() {
            if matches!(id.as_str(), "eq" | "monitor" | "fade") {
                continue;
            }
            others.push(id.clone());
        }

        (eq_info, others)
    };

    let mut db = ctx.core.db.lock().await;

    if eq_info.is_some()
        && let Ok(Some((enabled, bands))) = db.load_equalizer().await
    {
        // Re-acquire guard briefly to set values
        let guard = ctx.audio.effect_handles.read();
        if let Some(eq) = guard.get("eq") {
            eq.set_enabled(enabled);
            for (i, &gain) in bands.iter().enumerate() {
                eq.set_param(i, gain);
            }
        }
    }

    for id in other_effects {
        if let Ok(Some((enabled, params))) = db.load_effect(&id).await {
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
