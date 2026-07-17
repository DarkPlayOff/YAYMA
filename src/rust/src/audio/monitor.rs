use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
};

use crate::audio::fx::biquad::{FilterType, StereoBiquad};
use crate::util::reactive::Signal;

// Crossover points for the bass/mid/high split fed into the vibe visualizer.
// Real band-limited energy (via biquad filters below), not a proxy derived
// from the rectified signal's envelope dynamics.
const LOW_CUTOFF_HZ: f32 = 150.0;
const MID_CENTER_HZ: f32 = 1000.0;
const HIGH_CUTOFF_HZ: f32 = 4000.0;

/// Per-band biquad crossover filters used to derive real bass/mid/high
/// energy from the audio signal (as opposed to filtering the rectified
/// signal, which measures loudness-envelope dynamics rather than actual
/// frequency content).
struct BandFilters {
    low: StereoBiquad,
    mid: StereoBiquad,
    high: StereoBiquad,
    sample_rate: f32,
    low_l: Vec<f32>,
    low_r: Vec<f32>,
    mid_l: Vec<f32>,
    mid_r: Vec<f32>,
    high_l: Vec<f32>,
    high_r: Vec<f32>,
}

impl BandFilters {
    fn new() -> Self {
        Self {
            low: StereoBiquad::new(),
            mid: StereoBiquad::new(),
            high: StereoBiquad::new(),
            sample_rate: 0.0,
            low_l: Vec::new(),
            low_r: Vec::new(),
            mid_l: Vec::new(),
            mid_r: Vec::new(),
            high_l: Vec::new(),
            high_r: Vec::new(),
        }
    }

    fn configure(&mut self, sample_rate: f32) {
        if (self.sample_rate - sample_rate).abs() < 1.0 {
            return;
        }
        self.sample_rate = sample_rate;
        self.low
            .update(FilterType::LowPass, LOW_CUTOFF_HZ, 0.707, 0.0, sample_rate);
        self.mid
            .update(FilterType::BandPass, MID_CENTER_HZ, 0.6, 0.0, sample_rate);
        self.high
            .update(FilterType::HighPass, HIGH_CUTOFF_HZ, 0.707, 0.0, sample_rate);
        self.low.reset();
        self.mid.reset();
        self.high.reset();
    }

    fn ensure_capacity(&mut self, len: usize) {
        if self.low_l.len() < len {
            self.low_l.resize(len, 0.0);
            self.low_r.resize(len, 0.0);
            self.mid_l.resize(len, 0.0);
            self.mid_r.resize(len, 0.0);
            self.high_l.resize(len, 0.0);
            self.high_r.resize(len, 0.0);
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub struct AmplitudeTracker {
    current: AtomicU32,
    peak: AtomicU32,
    attack: f32,
    release: f32,
    peak_hold_samples: usize,
    samples_since_peak: AtomicUsize,
}

impl AmplitudeTracker {
    pub fn new(attack: f32, release: f32, peak_hold_ms: u32, sample_rate: u32) -> Self {
        let peak_hold_samples = (peak_hold_ms as f32 * sample_rate as f32 / 1000.0) as usize;
        Self {
            current: AtomicU32::new(0),
            peak: AtomicU32::new(0),
            attack: attack.clamp(0.0, 1.0),
            release: release.clamp(0.0, 1.0),
            peak_hold_samples,
            samples_since_peak: AtomicUsize::new(0),
        }
    }
    #[inline]
    pub fn process(&self, sample: f32) {
        let abs_sample = sample.abs();
        let current = f32::from_bits(self.current.load(Ordering::Relaxed));
        let new_value = if abs_sample > current {
            current + (abs_sample - current) * self.attack
        } else {
            current + (abs_sample - current) * self.release
        };
        self.current.store(new_value.to_bits(), Ordering::Relaxed);
        let peak = f32::from_bits(self.peak.load(Ordering::Relaxed));
        if abs_sample > peak {
            self.peak.store(abs_sample.to_bits(), Ordering::Relaxed);
            self.samples_since_peak.store(0, Ordering::Relaxed);
        } else {
            let samples = self.samples_since_peak.fetch_add(1, Ordering::Relaxed);
            if samples >= self.peak_hold_samples {
                let new_peak = peak * 0.995;
                self.peak.store(new_peak.to_bits(), Ordering::Relaxed);
            }
        }
    }
    #[inline]
    pub fn amplitude(&self) -> f32 {
        f32::from_bits(self.current.load(Ordering::Relaxed))
    }
    pub fn reset(&self) {
        self.current.store(0, Ordering::Relaxed);
        self.peak.store(0, Ordering::Relaxed);
        self.samples_since_peak.store(0, Ordering::Relaxed);
    }
}

impl Default for AmplitudeTracker {
    fn default() -> Self {
        Self::new(0.3, 0.05, 500, 44100)
    }
}
impl Clone for AmplitudeTracker {
    fn clone(&self) -> Self {
        Self {
            current: AtomicU32::new(self.current.load(Ordering::Relaxed)),
            peak: AtomicU32::new(self.peak.load(Ordering::Relaxed)),
            attack: self.attack,
            release: self.release,
            peak_hold_samples: self.peak_hold_samples,
            samples_since_peak: AtomicUsize::new(self.samples_since_peak.load(Ordering::Relaxed)),
        }
    }
}

struct MonitorInternal {
    combined_amplitude: AtomicU32,
    bass_amp: AtomicU32,
    mid_amp: AtomicU32,
    high_amp: AtomicU32,
    bands: Mutex<BandFilters>,
    position: AtomicU64,
    enabled: AtomicBool,
    focused: AtomicBool,
}

#[flutter_rust_bridge::frb(ignore)]
pub struct Monitor {
    pub amplitude_left: AmplitudeTracker,
    pub amplitude_right: AmplitudeTracker,
    pub vibe: Arc<tokio::sync::Mutex<crate::audio::vibe::VibeEngine>>,
    playing: Signal<bool>,
    internal: Arc<MonitorInternal>,
}

impl Monitor {
    pub fn new(_notify_samples: usize) -> Self {
        Self {
            amplitude_left: AmplitudeTracker::default(),
            amplitude_right: AmplitudeTracker::default(),
            vibe: Arc::new(tokio::sync::Mutex::new(
                crate::audio::vibe::VibeEngine::new(),
            )),
            playing: Signal::new(false),
            internal: Arc::new(MonitorInternal {
                combined_amplitude: AtomicU32::new(0),
                bass_amp: AtomicU32::new(0),
                mid_amp: AtomicU32::new(0),
                high_amp: AtomicU32::new(0),
                bands: Mutex::new(BandFilters::new()),
                position: AtomicU64::new(0),
                enabled: AtomicBool::new(true),
                focused: AtomicBool::new(true),
            }),
        }
    }

    /// (Re)configures the bass/mid/high crossover filters for the given
    /// sample rate. Called once per track load (sample rate can vary
    /// between tracks); cheap no-op if unchanged.
    pub fn configure(&self, sample_rate: f32) {
        if let Ok(mut bands) = self.internal.bands.lock() {
            bands.configure(sample_rate);
        }
    }

    #[inline]
    pub fn process_stereo(&self, left: f32, right: f32) {
        self.process_block(&[left], &[right]);
    }

    #[inline]
    pub fn process_block(&self, left: &[f32], right: &[f32]) {
        if !self.internal.enabled.load(Ordering::Relaxed) {
            return;
        }

        let len = left.len().min(right.len());
        if len == 0 {
            return;
        }

        let mut local_combined_amp_sum = 0.0f32;
        for i in 0..len {
            let l = left[i];
            let r = right[i];
            self.amplitude_left.process(l);
            self.amplitude_right.process(r);
            local_combined_amp_sum +=
                (self.amplitude_left.amplitude() + self.amplitude_right.amplitude()) * 0.5;
        }

        let avg_combined = local_combined_amp_sum / len as f32;
        self.internal
            .combined_amplitude
            .store(avg_combined.to_bits(), Ordering::Relaxed);
        self.internal
            .position
            .fetch_add(len as u64, Ordering::Relaxed);

        // Real frequency-selective bass/mid/high split, via biquad crossover
        // filters run over the actual (non-rectified) signal.
        if let Ok(mut bands) = self.internal.bands.lock() {
            bands.ensure_capacity(len);
            bands.low_l[..len].copy_from_slice(&left[..len]);
            bands.low_r[..len].copy_from_slice(&right[..len]);
            bands.mid_l[..len].copy_from_slice(&left[..len]);
            bands.mid_r[..len].copy_from_slice(&right[..len]);
            bands.high_l[..len].copy_from_slice(&left[..len]);
            bands.high_r[..len].copy_from_slice(&right[..len]);

            let BandFilters {
                low,
                mid,
                high,
                low_l,
                low_r,
                mid_l,
                mid_r,
                high_l,
                high_r,
                ..
            } = &mut *bands;
            low.process_block(&mut low_l[..len], &mut low_r[..len]);
            mid.process_block(&mut mid_l[..len], &mut mid_r[..len]);
            high.process_block(&mut high_l[..len], &mut high_r[..len]);

            let mut local_bass_peak = 0.0f32;
            let mut local_mid_peak = 0.0f32;
            let mut local_high_peak = 0.0f32;
            for i in 0..len {
                local_bass_peak = local_bass_peak.max(((low_l[i] + low_r[i]) * 0.5).abs());
                local_mid_peak = local_mid_peak.max(((mid_l[i] + mid_r[i]) * 0.5).abs());
                local_high_peak = local_high_peak.max(((high_l[i] + high_r[i]) * 0.5).abs());
            }

            let update_peak = |atomic: &AtomicU32, val: f32| {
                let mut cur = atomic.load(Ordering::Relaxed);
                while val > f32::from_bits(cur) {
                    match atomic.compare_exchange_weak(
                        cur,
                        val.to_bits(),
                        Ordering::Relaxed,
                        Ordering::Relaxed,
                    ) {
                        Ok(_) => break,
                        Err(a) => cur = a,
                    }
                }
            };

            update_peak(&self.internal.bass_amp, local_bass_peak);
            update_peak(&self.internal.mid_amp, local_mid_peak);
            update_peak(&self.internal.high_amp, local_high_peak);
        }
    }

    #[inline]
    pub fn vibe_bands(&self) -> [f32; 3] {
        [
            f32::from_bits(self.internal.bass_amp.swap(0, Ordering::Relaxed)),
            f32::from_bits(self.internal.mid_amp.swap(0, Ordering::Relaxed)),
            f32::from_bits(self.internal.high_amp.swap(0, Ordering::Relaxed)),
        ]
    }

    #[inline]
    pub fn combined_amplitude(&self) -> f32 {
        f32::from_bits(self.internal.combined_amplitude.load(Ordering::Relaxed))
    }
    #[inline]
    pub fn set_enabled(&self, v: bool) {
        self.internal.enabled.store(v, Ordering::Relaxed);
    }
    #[inline]
    pub fn set_focused(&self, v: bool) {
        self.internal.focused.store(v, Ordering::Relaxed);
    }
    #[inline]
    pub fn is_focused(&self) -> bool {
        self.internal.focused.load(Ordering::Relaxed)
    }
    pub fn set_playing(&self, v: bool) {
        self.playing.set(v);
    }
    pub fn is_playing(&self) -> bool {
        self.playing.get()
    }
    pub fn position(&self) -> u64 {
        self.internal.position.load(Ordering::Relaxed)
    }
    pub fn reset_position(&self) {
        self.internal.position.store(0, Ordering::Relaxed);
        self.amplitude_left.reset();
        self.amplitude_right.reset();
        self.internal.combined_amplitude.store(0, Ordering::Relaxed);
    }
}

impl Default for Monitor {
    fn default() -> Self {
        Self::new(1024)
    }
}
impl Clone for Monitor {
    fn clone(&self) -> Self {
        Self {
            amplitude_left: self.amplitude_left.clone(),
            amplitude_right: self.amplitude_right.clone(),
            vibe: self.vibe.clone(),
            playing: self.playing.clone(),
            internal: self.internal.clone(),
        }
    }
}
