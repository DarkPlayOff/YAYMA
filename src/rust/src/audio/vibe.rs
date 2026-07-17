use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

pub struct VibeEngine {
    time: f32,
    energy_target: AtomicU32,
    smoothed_energy: f32,

    audio_values: [f32; 3],
    max_observed: [f32; 3],

    // Onset ("beat") detection state per band: a fast envelope vs. a slow
    // baseline, so a genuine percussive hit (fast >> slow) is told apart
    // from just a loud sustained passage (fast ~= slow, both high).
    fast_env: [f32; 3],
    slow_env: [f32; 3],
    beat_cooldown: [f32; 3],
    beat_pulse: [f32; 3],
    // Whether a band's pulse is still ramping up toward its onset peak
    // (see ATTACK_RATE in tick()) rather than already decaying.
    beat_rising: [bool; 3],

    react: [f32; 3],
    like_start_time: Option<Instant>,
    is_liking: bool,

    current_colors: [f32; 18],
    target_colors: [f32; 18],

    last_tick: Instant,
}

impl Default for VibeEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl VibeEngine {
    pub fn new() -> Self {
        let default_colors = [
            0.9, 0.8, 0.1, 0.8, 0.1, 0.5, 0.5, 0.1, 0.9, 0.4, 0.3, 0.0, 0.4, 0.0, 0.2, 0.2, 0.0,
            0.4,
        ];
        Self {
            time: rand::random::<f32>() * 3600.0,
            energy_target: AtomicU32::new(0.4f32.to_bits()),
            smoothed_energy: 0.4,
            audio_values: [0.0; 3],
            max_observed: [0.05, 0.02, 0.01],
            fast_env: [0.0; 3],
            slow_env: [0.0; 3],
            beat_cooldown: [0.0; 3],
            beat_pulse: [0.0; 3],
            beat_rising: [false; 3],
            react: [0.0; 3],
            like_start_time: None,
            is_liking: false,
            current_colors: default_colors,
            target_colors: default_colors,
            last_tick: Instant::now(),
        }
    }

    pub fn set_playing(&self, playing: bool) {
        let target: f32 = if playing { 1.2 } else { 0.4 };
        self.energy_target
            .store(target.to_bits(), Ordering::Relaxed);
    }

    pub fn trigger_like(&mut self) {
        self.like_start_time = Some(Instant::now());
        self.is_liking = true;
    }

    /// Forgets the per-band loudness/onset history. Without this, switching
    /// from a loud track to a quiet one leaves `max_observed` inflated for
    /// several seconds (it only decays ~0.5%/tick), so the new track's
    /// audio reacts as if it were much quieter than it actually is until
    /// that stale peak fades out on its own.
    pub fn reset_audio_envelopes(&mut self) {
        self.audio_values = [0.0; 3];
        self.max_observed = [0.05, 0.02, 0.01];
        self.fast_env = [0.0; 3];
        self.slow_env = [0.0; 3];
        self.beat_cooldown = [0.0; 3];
        self.beat_pulse = [0.0; 3];
        self.beat_rising = [false; 3];
    }

    pub fn set_palette(&mut self, colors: Vec<f32>) {
        debug_assert_eq!(colors.len(), 18, "Expected exactly 18 color values");
        if colors.len() == 18 {
            self.target_colors.copy_from_slice(&colors);
        }
    }

    pub fn tick(&mut self, bands: [f32; 3]) -> [f32; 26] {
        let now = Instant::now();
        // Clamp dt so a stall (e.g. window unfocused, debugger pause) can't
        // cause a single tick to fast-forward every envelope.
        let dt = now.duration_since(self.last_tick).as_secs_f32().min(0.1);
        self.last_tick = now;

        let target = f32::from_bits(self.energy_target.load(Ordering::Relaxed));
        let energy_lerp = (dt * 6.0).min(1.0);
        self.smoothed_energy += (target - self.smoothed_energy) * energy_lerp;

        const DECAY_RATES: [f32; 3] = [2.4, 1.5, 1.5];
        // How much of a band's ambient (non-beat) loudness still shows, so
        // sustained passages (pads, wide choruses) aren't fully dark between
        // beats — the beat pulse is layered on top of this.
        const AMBIENT_WEIGHT: f32 = 0.45;
        const FAST_RATE: f32 = 20.0;
        const SLOW_RATE: f32 = 2.5;
        // How far the fast envelope must clear the slow baseline to count
        // as an onset. Bass needs a clearer jump (kicks are sparse and
        // punchy); highs trigger more readily (hi-hats/cymbals are dense).
        const BEAT_RATIO: [f32; 3] = [1.3, 1.25, 1.2];
        const BEAT_MIN_LEVEL: [f32; 3] = [0.15, 0.12, 0.1];
        // Refractory period per band, so a single hit's decay tail can't
        // retrigger — also caps how fast each band can visually pulse.
        const BEAT_MIN_INTERVAL: [f32; 3] = [0.15, 0.12, 0.08];
        // How fast a triggered pulse ramps up to its peak. Bass is
        // deliberately the slowest so a heavy sub-kick (e.g. dubstep drops)
        // reads as a punch rather than an instant, jarring flash; mid/high
        // stay snappy since hi-hats/cymbals read better as sharp transients.
        const ATTACK_RATE: [f32; 3] = [9.0, 15.0, 19.0];

        for i in 0..3 {
            self.max_observed[i] = (self.max_observed[i] * 0.995).max(0.01);
            if bands[i] > self.max_observed[i] {
                self.max_observed[i] = bands[i];
            }
            let normalized = (bands[i] / self.max_observed[i]).min(1.5);

            let fast_lerp = (dt * FAST_RATE).min(1.0);
            let slow_lerp = (dt * SLOW_RATE).min(1.0);
            self.fast_env[i] += (normalized - self.fast_env[i]) * fast_lerp;
            self.slow_env[i] += (normalized - self.slow_env[i]) * slow_lerp;

            self.beat_cooldown[i] = (self.beat_cooldown[i] - dt).max(0.0);

            let is_onset = self.beat_cooldown[i] <= 0.0
                && normalized > BEAT_MIN_LEVEL[i]
                && self.fast_env[i] > self.slow_env[i] * BEAT_RATIO[i];

            if is_onset {
                self.beat_cooldown[i] = BEAT_MIN_INTERVAL[i];
                self.beat_rising[i] = true;
            }

            if self.beat_rising[i] {
                let attack_lerp = (dt * ATTACK_RATE[i]).min(1.0);
                self.beat_pulse[i] += (1.0 - self.beat_pulse[i]) * attack_lerp;
                if self.beat_pulse[i] > 0.98 {
                    self.beat_rising[i] = false;
                }
            } else {
                self.beat_pulse[i] = (self.beat_pulse[i] - DECAY_RATES[i] * dt).max(0.0);
            }

            self.audio_values[i] = (normalized * AMBIENT_WEIGHT + self.beat_pulse[i]).min(1.5);
        }

        if self.is_liking {
            if let Some(start) = self.like_start_time {
                let elapsed = start.elapsed().as_millis() as f32;
                for i in 0..3 {
                    let delay = match i {
                        0 => 0.0,
                        1 => 100.0,
                        _ => 150.0,
                    };
                    let t = elapsed - delay;
                    self.react[i] = if t < 0.0 {
                        0.0
                    } else if t < 400.0 {
                        0.7 * (t / 400.0)
                    } else if t < 850.0 {
                        0.7
                    } else if t < 1050.0 {
                        0.7 * (1.0 - (t - 850.0) / 200.0)
                    } else {
                        0.0
                    }
                    .max(0.0);
                }
                if elapsed > 1200.0 {
                    self.is_liking = false;
                }
            }
        } else {
            self.react = [0.0; 3];
        }

        let instant_boost = self.audio_values[0] * 1.8;
        self.time = (self.time + (self.smoothed_energy + instant_boost) * dt) % 86400.0;

        let color_lerp = (dt * 1.5).min(1.0);
        for i in 0..18 {
            self.current_colors[i] += (self.target_colors[i] - self.current_colors[i]) * color_lerp;
        }

        let mut out = [0.0f32; 26];
        out[0] = self.time;
        out[1] = self.smoothed_energy;
        out[2..5].copy_from_slice(&self.audio_values);
        out[5..8].copy_from_slice(&self.react);
        out[8..26].copy_from_slice(&self.current_colors);
        out
    }
}
