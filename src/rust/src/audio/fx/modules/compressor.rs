use crate::audio::fx::Effect;
use crate::audio::fx::param::EffectParams;
use std::sync::Arc;

pub struct CompressorEffect {
    params: Arc<EffectParams>,
    envelope_l: f32,
    envelope_r: f32,
    sample_rate: f32,
    /// Derived from params; recomputed only when EffectParams::version changes.
    threshold_lin: f32,
    makeup_lin: f32,
    attack_coef: f32,
    release_coef: f32,
    /// Gain-curve exponent: 1 - 1/ratio. gain = (threshold/envelope)^gain_exp.
    gain_exp: f32,
    last_version: u32,
}

impl CompressorEffect {
    pub fn new(params: Arc<EffectParams>, sample_rate: f32) -> Self {
        Self {
            params,
            envelope_l: 0.0,
            envelope_r: 0.0,
            sample_rate,
            threshold_lin: 1.0,
            makeup_lin: 1.0,
            attack_coef: 0.0,
            release_coef: 0.0,
            gain_exp: 0.75,
            last_version: 0,
        }
    }

    #[inline]
    fn db_to_linear(db: f32) -> f32 {
        10.0_f32.powf(db / 20.0)
    }

    fn recompute(&mut self) {
        let threshold_db = self.params.get(0);
        let ratio = self.params.get(1).max(1.0);
        let attack_ms = self.params.get(2).max(0.1);
        let release_ms = self.params.get(3).max(10.0);

        self.threshold_lin = Self::db_to_linear(threshold_db);

        let makeup_db = (-threshold_db) * (1.0 - 1.0 / ratio) * 0.5;
        self.makeup_lin = Self::db_to_linear(makeup_db);

        self.attack_coef = (-1.0 / (attack_ms * 0.001 * self.sample_rate)).exp();
        self.release_coef = (-1.0 / (release_ms * 0.001 * self.sample_rate)).exp();
        self.gain_exp = 1.0 - 1.0 / ratio;
    }
}

impl Effect for CompressorEffect {
    fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
        if self.last_version != self.params.version() {
            self.last_version = self.params.version();
            self.recompute();
        }

        let threshold_lin = self.threshold_lin;
        let makeup_lin = self.makeup_lin;
        let attack_coef = self.attack_coef;
        let release_coef = self.release_coef;
        let gain_exp = self.gain_exp;

        for (l, r) in left.iter_mut().zip(right.iter_mut()) {
            let input_level = (l.abs().max(r.abs())).max(1e-6);

            let coef = if input_level > self.envelope_l {
                attack_coef
            } else {
                release_coef
            };
            self.envelope_l = coef * self.envelope_l + (1.0 - coef) * input_level;

            // Above threshold: gain = 10^(-(20*log10(env/thr) * k)/20)
            // expressed directly as (thr/env)^k — one powf, no per-sample
            // log10 or atomic param reads.
            let gain = if self.envelope_l > threshold_lin {
                (threshold_lin / self.envelope_l).powf(gain_exp)
            } else {
                1.0
            };

            *l *= gain * makeup_lin;
            *r *= gain * makeup_lin;
        }

        self.envelope_r = self.envelope_l;
    }

    fn reset(&mut self) {
        self.envelope_l = 0.0;
        self.envelope_r = 0.0;
    }
}
