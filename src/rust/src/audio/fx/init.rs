use crate::audio::fx::{EffectHandle, FxSource, modules::*};
use foldhash::HashMap;
use foldhash::HashMapExt;
use rodio::Source;

pub fn init_all<T: Source<Item = f32> + Send + 'static>(source: &mut FxSource<T>) {
    let sr = source.sample_rate().get() as f32;

    let fx = eq(sr);
    source.add_effect("eq", "Equalizer", fx.0, fx.1);

    let fx = chorus(sr);
    source.add_effect("chorus", "Chorus", fx.0, fx.1);

    let fx = lowpass(sr);
    source.add_effect("lowpass", "Lowpass", fx.0, fx.1);

    let fx = highpass(sr);
    source.add_effect("highpass", "Highpass", fx.0, fx.1);

    let fx = bandpass(sr);
    source.add_effect("bandpass", "Bandpass", fx.0, fx.1);

    let fx = notch(sr);
    source.add_effect("notch", "Notch", fx.0, fx.1);

    let fx = dc_block(sr);
    source.add_effect("dc_block", "DC Block", fx.0, fx.1);

    let fx = reverb(sr);
    source.add_effect("reverb", "Reverb", fx.0, fx.1);

    let fx = delay(sr);
    source.add_effect("delay", "Delay", fx.0, fx.1);

    let fx = compressor(sr);
    source.add_effect("compressor", "Compressor", fx.0, fx.1);

    let fx = overdrive(sr);
    source.add_effect("overdrive", "Overdrive", fx.0, fx.1);
}

pub fn create_templates() -> HashMap<String, EffectHandle> {
    let mut map = HashMap::new();
    let sr = 44100.0;

    let fx = eq(sr);
    map.insert(
        "eq".to_string(),
        EffectHandle {
            id: "eq".to_string(),
            name: "Equalizer".to_string(),
            params: fx.1,
        },
    );

    let fx = chorus(sr);
    map.insert(
        "chorus".to_string(),
        EffectHandle {
            id: "chorus".to_string(),
            name: "Chorus".to_string(),
            params: fx.1,
        },
    );

    let fx = lowpass(sr);
    map.insert(
        "lowpass".to_string(),
        EffectHandle {
            id: "lowpass".to_string(),
            name: "Lowpass".to_string(),
            params: fx.1,
        },
    );

    let fx = highpass(sr);
    map.insert(
        "highpass".to_string(),
        EffectHandle {
            id: "highpass".to_string(),
            name: "Highpass".to_string(),
            params: fx.1,
        },
    );

    let fx = bandpass(sr);
    map.insert(
        "bandpass".to_string(),
        EffectHandle {
            id: "bandpass".to_string(),
            name: "Bandpass".to_string(),
            params: fx.1,
        },
    );

    let fx = notch(sr);
    map.insert(
        "notch".to_string(),
        EffectHandle {
            id: "notch".to_string(),
            name: "Notch".to_string(),
            params: fx.1,
        },
    );

    let fx = dc_block(sr);
    map.insert(
        "dc_block".to_string(),
        EffectHandle {
            id: "dc_block".to_string(),
            name: "DC Block".to_string(),
            params: fx.1,
        },
    );

    let fx = reverb(sr);
    map.insert(
        "reverb".to_string(),
        EffectHandle {
            id: "reverb".to_string(),
            name: "Reverb".to_string(),
            params: fx.1,
        },
    );

    let fx = delay(sr);
    map.insert(
        "delay".to_string(),
        EffectHandle {
            id: "delay".to_string(),
            name: "Delay".to_string(),
            params: fx.1,
        },
    );

    let fx = compressor(sr);
    map.insert(
        "compressor".to_string(),
        EffectHandle {
            id: "compressor".to_string(),
            name: "Compressor".to_string(),
            params: fx.1,
        },
    );

    let fx = overdrive(sr);
    map.insert(
        "overdrive".to_string(),
        EffectHandle {
            id: "overdrive".to_string(),
            name: "Overdrive".to_string(),
            params: fx.1,
        },
    );

    map
}
