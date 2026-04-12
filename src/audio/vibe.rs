use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Instant;

pub struct VibeEngine {
    time: f32,
    energy_target: AtomicU32,
    smoothed_energy: f32,

    audio_values: [f32; 3],
    max_observed: [f32; 3],

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

    pub fn set_palette(&mut self, colors: Vec<f32>) {
        debug_assert_eq!(colors.len(), 18, "Expected exactly 18 color values");
        if colors.len() == 18 {
            self.target_colors.copy_from_slice(&colors);
        }
    }

    pub fn tick(&mut self, bands: [f32; 3]) -> Vec<f32> {
        let now = Instant::now();
        let dt = now.duration_since(self.last_tick).as_secs_f32();
        self.last_tick = now;

        let target = f32::from_bits(self.energy_target.load(Ordering::Relaxed));
        let energy_lerp = (dt * 6.0).min(1.0);
        self.smoothed_energy += (target - self.smoothed_energy) * energy_lerp;

        const DECAY_RATES: [f32; 3] = [3.5, 2.0, 2.0];
        for i in 0..3 {
            self.max_observed[i] = (self.max_observed[i] * 0.995).max(0.01);
            if bands[i] > self.max_observed[i] {
                self.max_observed[i] = bands[i];
            }
            let normalized = (bands[i] / self.max_observed[i]).min(1.5);
            if normalized > self.audio_values[i] {
                self.audio_values[i] = normalized;
            } else {
                self.audio_values[i] = (self.audio_values[i] - DECAY_RATES[i] * dt).max(0.0);
            }
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

        let mut out = Vec::with_capacity(26);
        out.push(self.time);
        out.push(self.smoothed_energy);
        out.extend_from_slice(&self.audio_values);
        out.extend_from_slice(&self.react);
        out.extend_from_slice(&self.current_colors);
        out
    }
}
