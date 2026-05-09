use crate::app::AppContext;
use crate::audio::commands::AudioMessage;

pub async fn load_persisted_settings(ctx: &AppContext) {
    let volume = {
        let db = ctx.core.db.lock();
        db.load_volume().ok()
    };

    if let Some(volume) = volume {
        let _ = ctx.audio.tx.send(AudioMessage::SetVolume(volume)).await;
    }

    if let Ok(quality) = ctx.core.db.lock().load_audio_quality() {
        ctx.core.api.set_quality(quality);
    }

    if let Ok(rpc_enabled) = ctx.core.db.lock().load_discord_rpc() {
        ctx.audio.signals.discord_rpc.set(rpc_enabled);
    }

    let db = ctx.core.db.lock();
    let guard = ctx.audio.effect_handles.read();

    if let Some(eq) = guard.get("eq")
        && let Ok(Some((enabled, bands))) = db.load_equalizer()
    {
        eq.set_enabled(enabled);
        for (i, &gain) in bands.iter().enumerate() {
            eq.set_param(i, gain);
        }
    }

    for (id, handle) in guard.iter() {
        if matches!(id.as_str(), "eq" | "monitor" | "fade") {
            continue;
        }
        if let Ok(Some((enabled, params))) = db.load_effect(id) {
            handle.set_enabled(enabled);
            for (i, &val) in params.iter().enumerate() {
                handle.set_param(i, val);
            }
        }
    }
}
