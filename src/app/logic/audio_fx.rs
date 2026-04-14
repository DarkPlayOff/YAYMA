use crate::api::models::{AudioEffectDto, AudioQuality, BandDto, EffectParamDto, EqualizerDto};
use crate::app::{AppContext, SETTINGS_CHANGED};
use crate::audio::commands::AudioMessage;

pub async fn get_audio_quality(ctx: &AppContext) -> AudioQuality {
    ctx.api.get_quality()
}

pub async fn set_audio_quality(ctx: &AppContext, quality: AudioQuality) {
    ctx.api.set_quality(quality);
    SETTINGS_CHANGED.notify_one();
    let _ = ctx.audio_tx.send(AudioMessage::ReloadCurrentTrack).await;
}

pub async fn trigger_vibe_like(ctx: &AppContext) {
    if let Ok(mut vibe) = ctx.signals.monitor.vibe.try_lock() {
        vibe.trigger_like();
    }
}

pub async fn set_vibe_palette(ctx: &AppContext, colors: Vec<f32>) {
    if let Ok(mut vibe) = ctx.signals.monitor.vibe.try_lock() {
        vibe.set_palette(colors);
    }
}

pub async fn get_equalizer(ctx: &AppContext) -> Option<EqualizerDto> {
    let guard = ctx.effect_handles.read();
    let eq = guard.get("eq")?;

    let mut bands = Vec::new();
    for i in 0..eq.param_count() {
        bands.push(BandDto {
            frequency: crate::audio::fx::modules::eq::EQ_FREQUENCIES[i],
            gain_db: eq.get_param(i),
            index: i as u32,
        });
    }

    Some(EqualizerDto {
        enabled: eq.is_enabled(),
        bands,
    })
}

pub async fn set_equalizer_enabled(ctx: &AppContext, enabled: bool) {
    let guard = ctx.effect_handles.read();
    if let Some(eq) = guard.get("eq") {
        eq.set_enabled(enabled);
        SETTINGS_CHANGED.notify_one();
    }
}

pub async fn set_equalizer_band(ctx: &AppContext, index: u32, gain_db: f32) {
    let guard = ctx.effect_handles.read();
    if let Some(eq) = guard.get("eq") {
        eq.set_param(index as usize, gain_db);
        SETTINGS_CHANGED.notify_one();
    }
}

pub async fn get_audio_effects(ctx: &AppContext) -> Vec<AudioEffectDto> {
    let guard = ctx.effect_handles.read();

    let mut effects = Vec::new();
    for (id, handle) in guard.iter() {
        if id == "eq" || id == "monitor" || id == "fade" {
            continue;
        }
        let mut params = Vec::new();
        let info = handle.params.info();
        for (i, p) in info.iter().enumerate() {
            params.push(EffectParamDto {
                name: p.name.to_string(),
                value: handle.get_param(i),
                default_value: p.default,
                min: p.min,
                max: p.max,
                step: p.step,
                unit: p.unit.to_string(),
                index: i as u32,
            });
        }
        effects.push(AudioEffectDto {
            id: id.clone(),
            name: handle.name.clone(),
            enabled: handle.is_enabled(),
            params,
        });
    }
    effects.sort_by(|a, b| a.name.cmp(&b.name));
    effects
}

pub async fn reset_effect(ctx: &AppContext, id: String) {
    let guard = ctx.effect_handles.read();
    if let Some(h) = guard.get(&id) {
        let info = h.params.info();
        for (i, p) in info.iter().enumerate() {
            h.set_param(i, p.default);
        }
        SETTINGS_CHANGED.notify_one();
    }
}

pub async fn set_effect_enabled(ctx: &AppContext, id: String, enabled: bool) {
    let guard = ctx.effect_handles.read();
    if let Some(h) = guard.get(&id) {
        h.set_enabled(enabled);
        SETTINGS_CHANGED.notify_one();
    }
}

pub async fn set_effect_param(ctx: &AppContext, id: String, index: u32, value: f32) {
    let guard = ctx.effect_handles.read();
    if let Some(h) = guard.get(&id) {
        h.set_param(index as usize, value);
        SETTINGS_CHANGED.notify_one();
    }
}
