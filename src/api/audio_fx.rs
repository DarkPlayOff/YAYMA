use crate::api::models::{AudioEffectDto, AudioQuality, EqualizerDto};
use crate::app::AppContext;
use crate::app::logic::audio_fx as logic;

pub async fn get_audio_quality(ctx: &AppContext) -> AudioQuality {
    logic::get_audio_quality(ctx).await
}

pub async fn set_audio_quality(ctx: &AppContext, quality: AudioQuality) {
    logic::set_audio_quality(ctx, quality).await
}

pub async fn trigger_vibe_like(ctx: &AppContext) {
    logic::trigger_vibe_like(ctx).await
}

pub async fn set_vibe_palette(ctx: &AppContext, colors: Vec<f32>) {
    logic::set_vibe_palette(ctx, colors).await
}

pub async fn get_equalizer(ctx: &AppContext) -> Option<EqualizerDto> {
    logic::get_equalizer(ctx).await
}

pub async fn set_equalizer_enabled(ctx: &AppContext, enabled: bool) {
    logic::set_equalizer_enabled(ctx, enabled).await
}

pub async fn set_equalizer_band(ctx: &AppContext, index: u32, gain_db: f32) {
    logic::set_equalizer_band(ctx, index, gain_db).await
}

pub async fn get_audio_effects(ctx: &AppContext) -> Vec<AudioEffectDto> {
    logic::get_audio_effects(ctx).await
}

pub async fn reset_effect(ctx: &AppContext, id: String) {
    logic::reset_effect(ctx, id).await
}

pub async fn set_effect_enabled(ctx: &AppContext, id: String, enabled: bool) {
    logic::set_effect_enabled(ctx, id, enabled).await
}

pub async fn set_effect_param(ctx: &AppContext, id: String, index: u32, value: f32) {
    logic::set_effect_param(ctx, id, index, value).await
}
