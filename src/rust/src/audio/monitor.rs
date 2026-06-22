use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering},
};

use crate::util::reactive::Signal;

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
    low_filter: AtomicU32,
    mid_filter: AtomicU32,
    high_filter: AtomicU32,
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
                low_filter: AtomicU32::new(0),
                mid_filter: AtomicU32::new(0),
                high_filter: AtomicU32::new(0),
                position: AtomicU64::new(0),
                enabled: AtomicBool::new(true),
                focused: AtomicBool::new(true),
            }),
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

        let mut local_bass_peak = 0.0f32;
        let mut local_mid_peak = 0.0f32;
        let mut local_high_peak = 0.0f32;
        let mut local_combined_amp_sum = 0.0f32;

        let mut l_f = f32::from_bits(self.internal.low_filter.load(Ordering::Relaxed));
        let mut m_f = f32::from_bits(self.internal.mid_filter.load(Ordering::Relaxed));
        let mut h_f = f32::from_bits(self.internal.high_filter.load(Ordering::Relaxed));

        for i in 0..len {
            let l = left[i];
            let r = right[i];
            let mono = (l + r) * 0.5;
            let abs_mono = mono.abs();

            // Filter cascade
            let low = l_f + (abs_mono - l_f) * 0.05;
            l_f = low;

            let h_val = h_f + (abs_mono - h_f) * 0.4;
            let high = (abs_mono - h_val).abs();
            h_f = h_val;

            let mid_val = (abs_mono - low - high).abs();
            let mid = m_f + (mid_val - m_f) * 0.2;
            m_f = mid;

            local_bass_peak = local_bass_peak.max(low);
            local_mid_peak = local_mid_peak.max(mid);
            local_high_peak = local_high_peak.max(high);

            self.amplitude_left.process(l);
            self.amplitude_right.process(r);
            local_combined_amp_sum +=
                (self.amplitude_left.amplitude() + self.amplitude_right.amplitude()) * 0.5;
        }

        self.internal
            .low_filter
            .store(l_f.to_bits(), Ordering::Relaxed);
        self.internal
            .mid_filter
            .store(m_f.to_bits(), Ordering::Relaxed);
        self.internal
            .high_filter
            .store(h_f.to_bits(), Ordering::Relaxed);

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

        let avg_combined = local_combined_amp_sum / len as f32;
        self.internal
            .combined_amplitude
            .store(avg_combined.to_bits(), Ordering::Relaxed);
        self.internal
            .position
            .fetch_add(len as u64, Ordering::Relaxed);
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
