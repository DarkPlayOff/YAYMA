use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
};

use parking_lot::Mutex;

use crate::audio::fx::biquad::{FilterType, StereoBiquad};
use crate::util::reactive::Signal;

// Max frames processed in one realtime callback; band scratch buffers are
// preallocated to this in configure() so process_block never allocates.
const MAX_MONITOR_BLOCK: usize = 2048;

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
            // Still ensure scratch is preallocated even when rate is unchanged.
            self.ensure_capacity(MAX_MONITOR_BLOCK);
            return;
        }
        self.sample_rate = sample_rate;
        self.low
            .update(FilterType::LowPass, LOW_CUTOFF_HZ, 0.707, 0.0, sample_rate);
        self.mid
            .update(FilterType::BandPass, MID_CENTER_HZ, 0.6, 0.0, sample_rate);
        self.high.update(
            FilterType::HighPass,
            HIGH_CUTOFF_HZ,
            0.707,
            0.0,
            sample_rate,
        );
        self.low.reset();
        self.mid.reset();
        self.high.reset();
        self.ensure_capacity(MAX_MONITOR_BLOCK);
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

#[derive(Clone, Copy)]
struct EnvelopeState {
    current: f32,
    peak: f32,
    samples_since_peak: usize,
}

impl EnvelopeState {
    const IDLE: Self = Self {
        current: 0.0,
        peak: 0.0,
        samples_since_peak: 0,
    };
}

#[flutter_rust_bridge::frb(ignore)]
pub struct AmplitudeTracker {
    /// Per-sample envelope state. Only the audio thread mutates it, inside
    /// `process_block` (locked once per block, never per sample); the mutex
    /// exists solely so `reset()` from other threads stays race-free.
    state: Mutex<EnvelopeState>,
    /// Last smoothed value, published once per block for lock-free readers.
    published: AtomicU32,
    attack: f32,
    release: f32,
    peak_hold_samples: usize,
}

impl AmplitudeTracker {
    pub fn new(attack: f32, release: f32, peak_hold_ms: u32, sample_rate: u32) -> Self {
        let peak_hold_samples = (peak_hold_ms as f32 * sample_rate as f32 / 1000.0) as usize;
        Self {
            state: Mutex::new(EnvelopeState::IDLE),
            published: AtomicU32::new(0),
            attack: attack.clamp(0.0, 1.0),
            release: release.clamp(0.0, 1.0),
            peak_hold_samples,
        }
    }

    /// Smooth the envelope over one block of samples; returns the block mean
    /// of the smoothed value. Audio thread only.
    #[inline]
    pub fn process_block(&self, samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return self.amplitude();
        }
        let mut st = self.state.lock();
        let mut sum = 0.0f32;
        for &sample in samples {
            let abs_sample = sample.abs();
            let coef = if abs_sample > st.current {
                self.attack
            } else {
                self.release
            };
            st.current += (abs_sample - st.current) * coef;
            if abs_sample > st.peak {
                st.peak = abs_sample;
                st.samples_since_peak = 0;
            } else {
                st.samples_since_peak += 1;
            }
            sum += st.current;
        }
        // Decay the held peak once per audio block (not per sample: a
        // per-sample `* 0.995` at 48kHz collapses to zero in milliseconds
        // and flickers).
        if st.samples_since_peak >= self.peak_hold_samples {
            st.peak *= 0.995;
        }
        let last_current = st.current;
        let mean = sum / samples.len() as f32;
        drop(st);
        self.published
            .store(last_current.to_bits(), Ordering::Relaxed);
        mean
    }

    #[inline]
    pub fn amplitude(&self) -> f32 {
        f32::from_bits(self.published.load(Ordering::Relaxed))
    }
    pub fn reset(&self) {
        *self.state.lock() = EnvelopeState::IDLE;
        self.published.store(0, Ordering::Relaxed);
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
            state: Mutex::new(*self.state.lock()),
            published: AtomicU32::new(self.published.load(Ordering::Relaxed)),
            attack: self.attack,
            release: self.release,
            peak_hold_samples: self.peak_hold_samples,
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
        let internal = Arc::new(MonitorInternal {
            combined_amplitude: AtomicU32::new(0),
            bass_amp: AtomicU32::new(0),
            mid_amp: AtomicU32::new(0),
            high_amp: AtomicU32::new(0),
            bands: Mutex::new(BandFilters::new()),
            position: AtomicU64::new(0),
            enabled: AtomicBool::new(true),
            focused: AtomicBool::new(true),
        });
        // Preallocate band scratch outside the realtime thread.
        internal.bands.lock().ensure_capacity(MAX_MONITOR_BLOCK);
        Self {
            amplitude_left: AmplitudeTracker::default(),
            amplitude_right: AmplitudeTracker::default(),
            vibe: Arc::new(tokio::sync::Mutex::new(
                crate::audio::vibe::VibeEngine::new(),
            )),
            playing: Signal::new(false),
            internal,
        }
    }

    /// (Re)configures the bass/mid/high crossover filters for the given
    /// sample rate. Called once per track load (sample rate can vary
    /// between tracks); cheap no-op if unchanged.
    pub fn configure(&self, sample_rate: f32) {
        self.internal.bands.lock().configure(sample_rate);
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

        let avg_left = self.amplitude_left.process_block(&left[..len]);
        let avg_right = self.amplitude_right.process_block(&right[..len]);
        self.internal
            .combined_amplitude
            .store(((avg_left + avg_right) * 0.5).to_bits(), Ordering::Relaxed);
        self.internal
            .position
            .fetch_add(len as u64, Ordering::Relaxed);

        // Real frequency-selective bass/mid/high split, via biquad crossover
        // filters run over the actual (non-rectified) signal.
        // try_lock: never block the realtime thread on configure() from UI.
        if let Some(mut bands) = self.internal.bands.try_lock() {
            if bands.low_l.len() < len {
                // Scratch smaller than this block (configure() preallocates
                // MAX_MONITOR_BLOCK, so this is a fallback): skip band split
                // for this block instead of allocating in hot path.
                return;
            }
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
                // Max-hold with slow per-block decay so UI polling at any rate
                // sees a stable value instead of zeros (old swap-on-read).
                let cur = f32::from_bits(atomic.load(Ordering::Relaxed));
                let decayed = cur * 0.98;
                let target = val.max(decayed);
                atomic.store(target.to_bits(), Ordering::Relaxed);
            };

            update_peak(&self.internal.bass_amp, local_bass_peak);
            update_peak(&self.internal.mid_amp, local_mid_peak);
            update_peak(&self.internal.high_amp, local_high_peak);
        }
    }

    #[inline]
    pub fn vibe_bands(&self) -> [f32; 3] {
        // Non-destructive read: UI may poll at any rate without zeroing peaks.
        let b = [
            f32::from_bits(self.internal.bass_amp.load(Ordering::Relaxed)),
            f32::from_bits(self.internal.mid_amp.load(Ordering::Relaxed)),
            f32::from_bits(self.internal.high_amp.load(Ordering::Relaxed)),
        ];
        // Guard the shader against NaN poisoning.
        b.map(|v| if v.is_finite() { v } else { 0.0 })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vibe_bands_read_is_non_destructive() {
        let monitor = Monitor::new(1024);
        let block = vec![0.5f32; 256];
        monitor.process_block(&block, &block);
        let first = monitor.vibe_bands();
        assert!(first[0] > 0.1, "bass band must observe DC energy");
        // Old swap-on-read returned zeros on the second poll; max-hold keeps values.
        let second = monitor.vibe_bands();
        assert_eq!(first, second);
    }

    #[test]
    fn peak_decay_happens_per_block_not_per_sample() {
        // attack 1.0 (current follows input exactly), zero peak hold:
        // the block-end decay applies once per process_block call.
        let tracker = AmplitudeTracker::new(1.0, 0.0, 0, 44100);
        let mean = tracker.process_block(&[1.0]);
        assert_eq!(mean, 1.0);
        assert_eq!(tracker.amplitude(), 1.0);
        // 100 silent samples inside ONE block: exactly one decay, the peak
        // must survive (per-sample decay would have collapsed it).
        tracker.process_block(&[0.0; 100]);
        let peak = tracker.state.lock().peak;
        assert!(
            peak > 0.9,
            "peak must survive 100 silent samples in one block, got {peak}"
        );
        // release = 0.0 means the envelope itself never falls; only the peak decays.
        assert_eq!(tracker.amplitude(), 1.0);
        // Repeated blocks decay cumulatively: the peak block, the 100-sample
        // block and the 100 single-sample blocks each applied exactly one
        // 0.995 factor — 102 decays in total.
        for _ in 0..100 {
            tracker.process_block(&[0.0]);
        }
        let peak = tracker.state.lock().peak;
        let expected = 0.995f32.powi(102);
        assert!(
            (peak - expected).abs() < 1e-4,
            "peak must decay per block, got {peak}, expected ~{expected}"
        );
    }

    #[test]
    fn process_block_publishes_block_mean_and_last_current() {
        let tracker = AmplitudeTracker::new(1.0, 1.0, 1000, 44100);
        // attack = release = 1.0: current equals |input| every sample.
        let mean = tracker.process_block(&[0.0, 1.0]);
        assert!((mean - 0.5).abs() < 1e-6);
        assert_eq!(tracker.amplitude(), 1.0, "amplitude() must see last current");
    }

    #[test]
    fn reset_clears_envelope_and_publication() {
        let tracker = AmplitudeTracker::new(1.0, 1.0, 1000, 44100);
        tracker.process_block(&[0.7]);
        assert!(tracker.amplitude() > 0.0);
        tracker.reset();
        assert_eq!(tracker.amplitude(), 0.0);
        let st = tracker.state.lock();
        assert_eq!(st.current, 0.0);
        assert_eq!(st.peak, 0.0);
        assert_eq!(st.samples_since_peak, 0);
    }
}
