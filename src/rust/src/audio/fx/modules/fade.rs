use super::Effect;

pub struct FadeEffect {
    fade_in_start: u64,
    fade_in_end: u64,
    fade_out_start: u64,
    fade_out_end: u64,
    inv_fade_in_duration: f32,
    inv_fade_out_duration: f32,
    // u64, not f32: an f32 counter stops incrementing after 2^24 frames
    // (~5:48 at 48 kHz), which would freeze late fade-outs on long tracks.
    current_frame: u64,
}

impl FadeEffect {
    pub fn new(
        in_start: f32,
        in_stop: f32,
        out_start: f32,
        out_stop: f32,
        sample_rate: u32,
        _channels: u16,
    ) -> Self {
        // f64 multiply keeps the frame count exact well past 2^24.
        let to_frames = |t: f32| -> u64 { (t as f64 * sample_rate as f64).max(0.0) as u64 };
        let fade_in_start = to_frames(in_start);
        let fade_in_end = to_frames(in_stop);
        let fade_out_start = to_frames(out_start);
        let fade_out_end = to_frames(out_stop);
        let inv_fade_in_duration = (fade_in_end.saturating_sub(fade_in_start)) as f32;
        let inv_fade_out_duration = (fade_out_end.saturating_sub(fade_out_start)) as f32;
        Self {
            fade_in_start,
            fade_in_end,
            fade_out_start,
            fade_out_end,
            inv_fade_in_duration: if inv_fade_in_duration > 0.0 {
                1.0 / inv_fade_in_duration
            } else {
                0.0
            },
            inv_fade_out_duration: if inv_fade_out_duration > 0.0 {
                1.0 / inv_fade_out_duration
            } else {
                0.0
            },
            current_frame: 0,
        }
    }

    #[inline(always)]
    fn apply_gain(&self, pos: u64) -> f32 {
        if pos >= self.fade_in_end && pos < self.fade_out_start {
            return 1.0;
        }

        if pos < self.fade_in_end {
            if pos < self.fade_in_start {
                return 0.0;
            }
            return (pos - self.fade_in_start) as f32 * self.inv_fade_in_duration;
        }

        if pos >= self.fade_out_end {
            return 0.0;
        }
        1.0 - (pos - self.fade_out_start) as f32 * self.inv_fade_out_duration
    }
}

impl Effect for FadeEffect {
    #[inline]
    fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        let len = left.len().min(right.len());
        for i in 0..len {
            let gain = self.apply_gain(self.current_frame);
            left[i] *= gain;
            right[i] *= gain;
            self.current_frame += 1;
        }
    }

    fn reset(&mut self) {
        self.current_frame = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fade_in_and_out_ramp_correctly() {
        // 1 s fade-in, fade-out from 100 s to 101 s at 48 kHz.
        let mut fx = FadeEffect::new(0.0, 1.0, 100.0, 101.0, 48000, 2);

        // Halfway through the fade-in: gain 0.5.
        fx.current_frame = 24000;
        let mut l = [1.0f32; 1];
        let mut r = [1.0f32; 1];
        fx.process(&mut l, &mut r);
        assert!((l[0] - 0.5).abs() < 1e-4, "fade-in gain {}", l[0]);

        // Fully faded out past the fade-out end: gain 0.
        fx.current_frame = 101 * 48000 + 1;
        let mut l = [1.0f32; 1];
        let mut r = [1.0f32; 1];
        fx.process(&mut l, &mut r);
        assert_eq!(l[0], 0.0);
    }

    #[test]
    fn late_fade_out_survives_f32_precision_limit() {
        // Regression: an f32 frame counter saturates at 2^24 (~5:48 at 48 kHz),
        // so a fade-out scheduled past that point never fired. 390 s * 48 kHz
        // = 18.7M frames > 2^24.
        let mut fx = FadeEffect::new(0.0, 0.0, 390.0, 391.0, 48000, 2);

        // 2^25 frames (~11.6 min): far past both the fade-out start (18.72M)
        // and end (18.768M), so the whole ramp is over and gain is 0.
        // With the old f32 counter the position would have saturated below
        // fade_out_start and the gain would have stayed 1.0 forever.
        fx.current_frame = 1 << 25;
        let mut l = [1.0f32; 1];
        let mut r = [1.0f32; 1];
        fx.process(&mut l, &mut r);
        assert_eq!(l[0], 0.0, "gain must be 0 past a late fade-out end");

        // Halfway through that late fade-out ramp: gain 0.5.
        let mid = 390 * 48000 + 24000;
        fx.current_frame = mid;
        let mut l = [1.0f32; 1];
        let mut r = [1.0f32; 1];
        fx.process(&mut l, &mut r);
        assert!((l[0] - 0.5).abs() < 1e-4, "late fade-out ramp gain {}", l[0]);
    }

    #[test]
    fn frame_counter_advances_past_2pow24() {
        let mut fx = FadeEffect::new(0.0, 0.0, 400.0, 401.0, 48000, 2);
        fx.current_frame = (1 << 24) - 2;
        let mut l = [1.0f32; 8];
        let mut r = [1.0f32; 8];
        fx.process(&mut l, &mut r);
        assert!(
            fx.current_frame > 1 << 24,
            "u64 counter must advance through 2^24, got {}",
            fx.current_frame
        );
    }
}
