use crate::audio::fx::Effect;
use crate::audio::fx::biquad::FilterType;
use crate::audio::fx::biquad::StereoBiquad;
use crate::audio::fx::param::EffectParams;
use std::sync::Arc;

pub struct Equalizer {
    params: Arc<EffectParams>,
    bands: [StereoBiquad; 15],
    sample_rate: f32,
    /// Linear output gain that keeps the boosted curve under 0 dBFS.
    preamp: f32,
    /// EffectParams::version() at which band coefficients were last computed;
    /// 0 = never (params start at version 1).
    last_version: u32,
}

pub const EQ_FREQUENCIES: [f32; 15] = [
    25.0, 40.0, 63.0, 100.0, 160.0, 250.0, 400.0, 630.0, 1000.0, 1600.0, 2500.0, 4000.0, 6300.0,
    10000.0, 16000.0,
];
/// 2/3-octave spacing (see EQ_FREQUENCIES) → the classic graphic-EQ Q of
/// `sqrt(2^n) / (2^n - 1)` for n = 2/3. With Q = 1 the bands overlap so much
/// that one boosted slider bleeds +6 dB into both neighbours (and boosting all
/// bands sums to ~+16 dB instead of the requested +6).
const EQ_Q: f32 = 2.145;
/// Bands at or above this fraction of the sample rate are muted: clamped to
/// Nyquist they turn into passthroughs (16 kHz @ 32 kHz) or, worse, boost the
/// wrong frequency (10 kHz @ 16 kHz starts boosting 6 kHz).
const NYQUIST_MARGIN: f32 = 0.45;

impl Equalizer {
    pub fn new(params: Arc<EffectParams>, sample_rate: f32) -> Self {
        Self {
            params,
            bands: std::array::from_fn(|_| StereoBiquad::new()),
            sample_rate,
            preamp: 1.0,
            last_version: 0,
        }
    }

    /// Highest gain of the whole cascade between 20 Hz and Nyquist, in dB.
    fn peak_gain_db(&self) -> f32 {
        const STEPS: usize = 256;
        let max_freq = self.sample_rate * 0.49;
        let mut peak = f32::NEG_INFINITY;
        for step in 0..=STEPS {
            let t = step as f32 / STEPS as f32;
            let freq = 20.0 * (max_freq / 20.0).powf(t);
            let db: f32 = self
                .bands
                .iter()
                .map(|b| b.magnitude_db(freq, self.sample_rate))
                .sum();
            peak = peak.max(db);
        }
        peak
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
                    let freq = EQ_FREQUENCIES[i];
                    let gain = if freq < self.sample_rate * NYQUIST_MARGIN {
                        self.params.get(i)
                    } else {
                        0.0
                    };
                    biquad.update(FilterType::Peak, freq, EQ_Q, gain, self.sample_rate);
                }
                // Unity when the curve only cuts; otherwise trim exactly as
                // much as the loudest point of the curve boosts.
                self.preamp = 10.0f32.powf(-self.peak_gain_db().max(0.0) / 20.0);
            }
        }
        if flat {
            return;
        }
        for biquad in &mut self.bands {
            biquad.process_block(left, right);
        }
        if self.preamp != 1.0 {
            for sample in left.iter_mut().chain(right.iter_mut()) {
                *sample *= self.preamp;
            }
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

    /// Steady-state gain of the real effect on a sine at `freq`.
    fn render_gain_db(eq: &mut Equalizer, freq: f32, sample_rate: f32) -> f32 {
        use std::f32::consts::PI;

        const FRAMES: usize = 1 << 15;
        const SKIP: usize = 1 << 13;
        const BLOCK: usize = 512;

        let mut left: Vec<f32> = (0..FRAMES)
            .map(|i| (2.0 * PI * freq * i as f32 / sample_rate).sin())
            .collect();
        let mut right = left.clone();
        for start in (0..FRAMES).step_by(BLOCK) {
            eq.process(
                &mut left[start..start + BLOCK],
                &mut right[start..start + BLOCK],
            );
        }
        let rms_out =
            (left[SKIP..].iter().map(|v| v * v).sum::<f32>() / (FRAMES - SKIP) as f32).sqrt();
        // Input is a unit-amplitude sine, so its RMS is 1/√2.
        20.0 * (rms_out * 2.0_f32.sqrt()).log10()
    }

    /// The RBJ peaking filter is exact at its center frequency (|H(w0)| = A²),
    /// so every cut must hit the requested dB there. Positive curves are scaled
    /// down by the auto preamp, so accuracy is measured where preamp is unity.
    #[test]
    fn band_gain_matches_requested_db_at_center() {
        for sample_rate in [44_100.0f32, 48_000.0] {
            for (index, &freq) in EQ_FREQUENCIES.iter().enumerate() {
                let gain = -12.0f32;
                let params = eq_params();
                params.set(index, gain);
                let mut eq = Equalizer::new(params, sample_rate);
                let measured = render_gain_db(&mut eq, freq, sample_rate);
                assert!(
                    (measured - gain).abs() < 0.1,
                    "band {index} ({freq} Hz) at {sample_rate} Hz: \
                     asked {gain:+} dB, got {measured:+.3} dB"
                );
            }
        }
    }

    /// A slider must own its 2/3-octave slice: cutting 1 kHz by -12 dB may
    /// leak at most a quarter of that into the adjacent band centers
    /// (Q = 2.145 gives ~-2.6 dB; the old Q = 1.0 gave ~-6 dB).
    #[test]
    fn band_cut_does_not_bleed_into_neighbours() {
        let params = eq_params();
        params.set(8, -12.0); // 1 kHz
        for &freq in &[630.0f32, 1600.0] {
            let mut eq = Equalizer::new(params.clone(), 44_100.0);
            let leaked = render_gain_db(&mut eq, freq, 44_100.0);
            assert!(
                leaked > -3.5,
                "{freq} Hz leaked {leaked:+.2} dB from a -12 dB cut at 1 kHz"
            );
        }
    }

    /// A boosted curve must not push a full-scale signal past 0 dBFS.
    #[test]
    fn preamp_prevents_clipping_on_boost() {
        use std::f32::consts::PI;

        // The curve from the report: mild sliders, +2.36 dB where bands stack.
        let curve = [
            -1.4, -1.3, -1.0, -0.7, 0.9, 1.0, 1.8, 1.4, 1.0, 1.5, 1.5, -1.3, -1.3, -3.1, -2.0,
        ];
        let params = eq_params();
        for (index, &gain) in curve.iter().enumerate() {
            params.set(index, gain);
        }
        let mut eq = Equalizer::new(params, 44_100.0);

        // 403 Hz is where this curve peaks; a 0 dBFS tone there would clip
        // by +2.36 dB without the preamp.
        let mut left: Vec<f32> = (0..8192)
            .map(|i| (2.0 * PI * 403.0 * i as f32 / 44_100.0).sin())
            .collect();
        let mut right = left.clone();
        eq.process(&mut left, &mut right);
        let peak = left[2048..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(
            peak <= 1.005,
            "output peaked at {peak:.3} (would be ~1.36 without preamp)"
        );
    }

    /// Bands at or above 0.45·sample_rate are muted instead of being clamped
    /// onto Nyquist, which used to boost the wrong frequency.
    #[test]
    fn bands_above_nyquist_margin_are_muted() {
        // 16 kHz rate: 10 kHz and 16 kHz bands are unusable. Without the guard
        // the 10 kHz band was clamped to ~7.98 kHz and boosted 6 kHz.
        let params = eq_params();
        params.set(13, 12.0); // 10 kHz
        params.set(14, 12.0); // 16 kHz
        for &probe in &[6_000.0f32, 7_000.0] {
            let mut eq = Equalizer::new(params.clone(), 16_000.0);
            let measured = render_gain_db(&mut eq, probe, 16_000.0);
            assert!(
                measured.abs() < 0.1,
                "{probe} Hz gained {measured:+.2} dB from a muted band"
            );
        }
    }

    #[test]
    fn leaving_flat_recomputes_coefficients() {
        let params = eq_params();
        let mut eq = Equalizer::new(params.clone(), 44_100.0);
        let mut left = [1.0f32; 16];
        let mut right = [1.0f32; 16];
        eq.process(&mut left, &mut right); // flat: passthrough

        params.set(0, 12.0); // +12 dB @ 25 Hz
        // If coefficients were stale the filter would be identity and the
        // 25 Hz tone would sit 12 dB below the 1 kHz tone (preamp only).
        let center = render_gain_db(&mut eq, 25.0, 44_100.0);
        let reference = render_gain_db(&mut eq, 1_000.0, 44_100.0);
        assert!(
            center - reference > 10.0,
            "expected the 25 Hz band to be active after leaving flat, \
             center {center:+.2} dB vs 1 kHz {reference:+.2} dB"
        );
    }
}
