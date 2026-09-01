use crate::audio::fx::{Effect, EffectHandle, FxSource, modules::*, param::EffectParams};
use foldhash::HashMap;
use foldhash::HashMapExt;
use rodio::Source;
use std::sync::Arc;

type EffectFactory = fn(f32) -> (Box<dyn Effect>, Arc<EffectParams>);

const EFFECT_REGISTRY: &[(&str, &str, EffectFactory)] = &[
    ("eq", "Equalizer", eq),
    ("chorus", "Chorus", chorus),
    ("lowpass", "Lowpass", lowpass),
    ("highpass", "Highpass", highpass),
    ("bandpass", "Bandpass", bandpass),
    ("notch", "Notch", notch),
    ("dc_block", "DC Block", dc_block),
    ("reverb", "Reverb", reverb),
    ("delay", "Delay", delay),
    ("compressor", "Compressor", compressor),
    ("overdrive", "Overdrive", overdrive),
];

pub fn init_all<T: Source<Item = f32> + Send + 'static>(source: &mut FxSource<T>) {
    let sr = source.sample_rate().get() as f32;

    for &(id, name, factory) in EFFECT_REGISTRY {
        let (effect, params) = factory(sr);
        source.add_effect(id, name, effect, params);
    }
}

pub fn create_templates() -> HashMap<String, EffectHandle> {
    let mut map = HashMap::new();
    for &(id, name, factory) in EFFECT_REGISTRY {
        let (_, params) = factory(44100.0);
        map.insert(
            id.to_string(),
            EffectHandle {
                id: id.to_string(),
                name: name.to_string(),
                params,
            },
        );
    }

    map
}
