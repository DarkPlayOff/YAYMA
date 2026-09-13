use crate::audio::fx::Effect;
use crate::audio::fx::biquad::FilterType;
use crate::audio::fx::biquad::StereoBiquad;
use crate::audio::fx::param::EffectParams;
use std::sync::Arc;

pub struct Equalizer {
    params: Arc<EffectParams>,
    bands: [StereoBiquad; 15],
    sample_rate: f32,
    /// EffectParams::version() at which band coefficients were last computed;
    /// 0 = never (params start at version 1).
    last_version: u32,
}

pub const EQ_FREQUENCIES: [f32; 15] = [
    25.0, 40.0, 63.0, 100.0, 160.0, 250.0, 400.0, 630.0, 1000.0, 1600.0, 2500.0, 4000.0, 6300.0,
    10000.0, 16000.0,
];
const EQ_Q: f32 = 1.0;

impl Equalizer {
    pub fn new(params: Arc<EffectParams>, sample_rate: f32) -> Self {
        Self {
            params,
            bands: std::array::from_fn(|_| StereoBiquad::new()),
            sample_rate,
            last_version: 0,
        }
    }
}

impl Effect for Equalizer {
    fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        let version = self.params.version();
        let flat = self.params.all_zero();
        if version != self.last_version {
            self.last_version = version;
            if flat {
                // Entering flat: exact passthrough, drop filter memory so
                // leaving flat later doesn't replay stale ringing.
                for b in &mut self.bands {
                    b.reset();
                }
            } else {
                for (i, biquad) in self.bands.iter_mut().enumerate() {
                    biquad.update(
                        FilterType::Peak,
                        EQ_FREQUENCIES[i],
                        EQ_Q,
                        self.params.get(i),
                        self.sample_rate,
                    );
                }
            }
        }
        if flat {
            return;
        }
        for biquad in &mut self.bands {
            biquad.process_block(left, right);
        }
    }

    fn reset(&mut self) {
        for b in &mut self.bands {
            b.reset();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::fx::param::ParamInfo;

    fn eq_params() -> Arc<EffectParams> {
        let info: Vec<ParamInfo> = EQ_FREQUENCIES
            .iter()
            .map(|_| ParamInfo {
                name: "band",
                min: -12.0,
                max: 12.0,
                default: 0.0,
                step: 0.5,
                unit: "dB",
            })
            .collect();
        Arc::new(EffectParams::new(&info))
    }

    #[test]
    fn flat_eq_is_exact_passthrough() {
        let mut eq = Equalizer::new(eq_params(), 44100.0);
        let left_in: Vec<f32> = (0..64).map(|i| (i as f32 * 0.01).sin()).collect();
        let right_in: Vec<f32> = (0..64).map(|i| (i as f32 * 0.02).sin()).collect();
        let mut left = left_in.clone();
        let mut right = right_in.clone();
        // Two blocks: bypass must hold, not just on the first one.
        for _ in 0..2 {
            eq.process(&mut left, &mut right);
        }
        assert_eq!(left, left_in);
        assert_eq!(right, right_in);
    }

    #[test]
    fn leaving_flat_recomputes_coefficients() {
        let params = eq_params();
        let mut eq = Equalizer::new(params.clone(), 44100.0);
        let mut left = [1.0f32; 16];
        let mut right = [1.0f32; 16];
        eq.process(&mut left, &mut right); // flat: passthrough

        params.set(0, 12.0); // +12 dB @ 25 Hz
        let mut left2 = [1.0f32; 16];
        let mut right2 = [1.0f32; 16];
        for _ in 0..64 {
            eq.process(&mut left2, &mut right2);
        }
        // A 25 Hz tone-like DC ramp must now be boosted, not passed through.
        assert!(
            left2.iter().any(|&v| v > 1.5),
            "expected boost after leaving flat, got max {}",
            left2.iter().cloned().fold(0.0, f32::max)
        );
    }
}
