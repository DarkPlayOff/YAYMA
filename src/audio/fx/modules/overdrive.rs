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
    dry_buf: [f32; MAX_BLOCK],
}

impl OverdriveEffect {
    pub fn new(params: Arc<EffectParams>, sample_rate: f32) -> Self {
        Self {
            params,
            pre_filter: StereoBiquad::new(),
            tone_filter: StereoBiquad::new(),
            sample_rate,
            dry_buf: [0.0; MAX_BLOCK],
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

        let len = left.len().min(right.len()).min(MAX_BLOCK);

        // Save dry signal to stack buffer (no heap allocation)
        self.dry_buf[..len].copy_from_slice(&left[..len]);

        self.pre_filter
            .process_block(&mut left[..len], &mut right[..len]);

        for (l, r) in left[..len].iter_mut().zip(right[..len].iter_mut()) {
            *l = Self::soft_clip(*l * drive) * drive_inv;
            *r = Self::soft_clip(*r * drive) * drive_inv;
        }

        self.tone_filter
            .process_block(&mut left[..len], &mut right[..len]);

        for i in 0..len {
            left[i] = left[i] * mix + self.dry_buf[i] * dry;
            right[i] = right[i] * mix + self.dry_buf[i] * dry;
        }
    }

    fn reset(&mut self) {
        self.pre_filter.reset();
        self.tone_filter.reset();
    }
}
