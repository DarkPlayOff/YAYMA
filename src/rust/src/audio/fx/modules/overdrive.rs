use crate::audio::fx::Effect;
use crate::audio::fx::biquad::{FilterType, StereoBiquad};
use crate::audio::fx::param::EffectParams;
use std::sync::Arc;

const MAX_BLOCK: usize = 512;

pub struct OverdriveEffect {
    params: Arc<EffectParams>,
    pre_filter: StereoBiquad,
    tone_filter: StereoBiquad,
    sample_rate: f32,
    dry_l: [f32; MAX_BLOCK],
    dry_r: [f32; MAX_BLOCK],
}

impl OverdriveEffect {
    pub fn new(params: Arc<EffectParams>, sample_rate: f32) -> Self {
        Self {
            params,
            pre_filter: StereoBiquad::new(),
            tone_filter: StereoBiquad::new(),
            sample_rate,
            dry_l: [0.0; MAX_BLOCK],
            dry_r: [0.0; MAX_BLOCK],
        }
    }

    #[inline(always)]
    fn soft_clip(x: f32) -> f32 {
        if x > 1.0 {
            2.0 / 3.0
        } else if x < -1.0 {
            -2.0 / 3.0
        } else {
            x - x * x * x / 3.0
        }
    }
}

impl Effect for OverdriveEffect {
    fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        let drive = self.params.get(0) * 10.0 + 1.0;
        let drive_inv = 1.0 / drive.sqrt();
        let tone_cutoff = self.params.get(1);
        let mix = self.params.get(2);
        let dry = 1.0 - mix;

        self.pre_filter
            .update(FilterType::HighPass, 80.0, 0.707, 0.0, self.sample_rate);
        self.tone_filter.update(
            FilterType::LowPass,
            tone_cutoff,
            0.707,
            0.0,
            self.sample_rate,
        );

        let total = left.len().min(right.len());
        let mut offset = 0;
        while offset < total {
            let len = (total - offset).min(MAX_BLOCK);

            // Save dry signal per channel (no heap allocation)
            self.dry_l[..len].copy_from_slice(&left[offset..offset + len]);
            self.dry_r[..len].copy_from_slice(&right[offset..offset + len]);

            let (wl, wr) = (&mut left[offset..offset + len], &mut right[offset..offset + len]);
            self.pre_filter.process_block(wl, wr);

            for (l, r) in wl.iter_mut().zip(wr.iter_mut()) {
                *l = Self::soft_clip(*l * drive) * drive_inv;
                *r = Self::soft_clip(*r * drive) * drive_inv;
            }

            self.tone_filter.process_block(wl, wr);

            for i in 0..len {
                wl[i] = wl[i] * mix + self.dry_l[i] * dry;
                wr[i] = wr[i] * mix + self.dry_r[i] * dry;
            }

            offset += len;
        }
    }

    fn reset(&mut self) {
        self.pre_filter.reset();
        self.tone_filter.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn effect() -> (OverdriveEffect, Arc<EffectParams>) {
        let info = vec![
            crate::audio::fx::param::ParamInfo {
                name: "Drive",
                min: 0.0,
                max: 1.0,
                default: 0.5,
                step: 0.05,
                unit: "",
            },
            crate::audio::fx::param::ParamInfo {
                name: "Tone",
                min: 1000.0,
                max: 10000.0,
                default: 3000.0,
                step: 10.0,
                unit: "Hz",
            },
            crate::audio::fx::param::ParamInfo {
                name: "Mix",
                min: 0.0,
                max: 1.0,
                default: 0.5,
                step: 0.05,
                unit: "",
            },
        ];
        let params = Arc::new(EffectParams::new(&info));
        let effect = OverdriveEffect::new(params.clone(), 44100.0);
        (effect, params)
    }

    #[test]
    fn dry_mix_keeps_channels_separate() {
        let (mut fx, params) = effect();
        params.set(2, 0.0); // mix = 0 → pure dry
        let left_in: Vec<f32> = (0..256).map(|i| i as f32 / 256.0).collect();
        let right_in: Vec<f32> = (0..256).map(|i| 1.0 - i as f32 / 256.0).collect();
        let mut left = left_in.clone();
        let mut right = right_in.clone();
        fx.process(&mut left, &mut right);
        // Right dry must come from the RIGHT input, not the left.
        assert_eq!(left, left_in);
        assert_eq!(right, right_in);
    }

    #[test]
    fn blocks_larger_than_max_block_are_fully_processed() {
        let (mut fx, params) = effect();
        params.set(0, 0.0); // drive = 1.0
        params.set(2, 1.0); // mix = 1 → pure wet
        let mut left = vec![0.25f32; 600];
        let mut right = vec![0.25f32; 600];
        fx.process(&mut left, &mut right);
        // Tail past MAX_BLOCK (512) must be processed, not left as dry input.
        // The 80Hz highpass settles DC to ~0 well before sample 550.
        assert!((left[550] - 0.25).abs() > 0.01);
        assert!((right[550] - 0.25).abs() > 0.01);
        assert!(left.iter().all(|v| v.is_finite()));
    }
}
