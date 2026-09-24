use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU32, Ordering},
};

pub struct AtomicF32(AtomicU32);

impl AtomicF32 {
    #[inline(always)]
    pub fn new(val: f32) -> Self {
        Self(AtomicU32::new(val.to_bits()))
    }

    #[inline(always)]
    pub fn get(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }

    #[inline(always)]
    pub fn set(&self, val: f32) {
        self.0.store(val.to_bits(), Ordering::Relaxed);
    }
}

#[derive(Clone)]
pub struct ParamInfo {
    pub name: &'static str,
    pub min: f32,
    pub max: f32,
    pub default: f32,
    pub step: f32,
    pub unit: &'static str,
}

/// Shared RT-safe param store (atomics + version). DSP adapters read it via
/// `version()` polling; UI writes via `EffectHandle` (lock-free view, below).
pub struct EffectParams {
    enabled: AtomicBool,
    values: Vec<AtomicF32>,
    info: Vec<ParamInfo>,
    /// Bumped on every `set()` so realtime effects can cache derived
    /// coefficients and recompute them only when a parameter changed.
    /// Starts at 1 so `0` can serve as the "never computed" sentinel.
    version: AtomicU32,
}

unsafe impl Send for EffectParams {}
unsafe impl Sync for EffectParams {}

impl EffectParams {
    pub fn new(info: &[ParamInfo]) -> Self {
        Self {
            enabled: AtomicBool::new(false),
            values: info.iter().map(|p| AtomicF32::new(p.default)).collect(),
            info: info.to_vec(),
            version: AtomicU32::new(1),
        }
    }

    #[inline(always)]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    #[inline(always)]
    pub fn set_enabled(&self, val: bool) {
        self.enabled.store(val, Ordering::Relaxed);
    }

    #[inline(always)]
    pub fn version(&self) -> u32 {
        self.version.load(Ordering::Relaxed)
    }

    /// True when every parameter is exactly zero (flat EQ-style bypass).
    #[inline]
    pub fn all_zero(&self) -> bool {
        self.values.iter().all(|v| v.get() == 0.0)
    }

    #[inline(always)]
    pub fn get(&self, idx: usize) -> f32 {
        debug_assert!(idx < self.values.len(), "EffectParams::get OOB index {idx}");
        self.values.get(idx).map_or(0.0, |v| {
            let val = v.get();
            if val.is_finite() { val } else { 0.0 }
        })
    }

    #[inline(always)]
    pub fn set(&self, idx: usize, val: f32) {
        if !val.is_finite() {
            return;
        }
        if let Some(atomic) = self.values.get(idx) {
            let info = &self.info[idx];
            atomic.set(val.clamp(info.min, info.max));
            self.version.fetch_add(1, Ordering::Relaxed);
        } else {
            debug_assert!(false, "EffectParams::set OOB index {idx}");
        }
    }

    pub fn param_count(&self) -> usize {
        self.values.len()
    }

    /// Versioned snapshot for read-modify-write: returns current version plus
    /// a copy of all values. Pair with `apply_snapshot` to avoid lost updates
    /// during handle migration.
    pub fn snapshot(&self) -> (u32, Vec<f32>) {
        let version = self.version.load(Ordering::Relaxed);
        let values = (0..self.values.len()).map(|i| self.get(i)).collect();
        (version, values)
    }

    /// Restore a snapshot only if `version()` still equals `expected_version`.
    /// Single version bump on success; length mismatch or version conflict
    /// returns false. Best-effort guard (not strict CAS) — concurrent plain
    /// `set()` calls still apply.
    pub fn apply_snapshot(&self, expected_version: u32, values: &[f32]) -> bool {
        if values.len() != self.values.len() {
            return false;
        }
        if self.version.load(Ordering::Relaxed) != expected_version {
            return false;
        }
        for (i, atomic) in self.values.iter().enumerate() {
            let val = values[i];
            if !val.is_finite() {
                continue;
            }
            let info = &self.info[i];
            atomic.set(val.clamp(info.min, info.max));
        }
        self.version.fetch_add(1, Ordering::Relaxed);
        true
    }

    pub fn info(&self) -> &[ParamInfo] {
        &self.info
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> EffectParams {
        EffectParams::new(&[ParamInfo {
            name: "gain",
            min: 0.0,
            max: 1.0,
            default: 0.5,
            step: 0.1,
            unit: "",
        }])
    }

    #[test]
    fn nan_and_infinite_sets_are_ignored() {
        let p = params();
        p.set(0, f32::NAN);
        assert_eq!(p.get(0), 0.5);
        p.set(0, f32::INFINITY);
        assert_eq!(p.get(0), 0.5);
        p.set(0, f32::NEG_INFINITY);
        assert_eq!(p.get(0), 0.5);
    }

    #[test]
    fn values_are_clamped() {
        let p = params();
        p.set(0, 5.0);
        assert_eq!(p.get(0), 1.0);
        p.set(0, -5.0);
        assert_eq!(p.get(0), 0.0);
    }

    #[test]
    fn oob_access_never_corrupts_valid_params() {
        let p = params();
        // Out-of-bounds access must not touch valid slots in any profile:
        // debug builds trap via debug_assert, release builds ignore.
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            p.set(99, 1.0);
            p.get(99)
        }));
        assert_eq!(p.get(0), 0.5);
    }
}

/// UI-facing view: id/name for lookup plus a shared `Arc<EffectParams>`.
/// Lives in the `EffectChain` HashMap registry; never owns DSP state.
#[derive(Clone)]
pub struct EffectHandle {
    pub id: String,
    pub name: String,
    pub(crate) params: Arc<EffectParams>,
}

impl EffectHandle {
    pub fn is_enabled(&self) -> bool {
        self.params.is_enabled()
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.params.set_enabled(enabled);
    }

    pub fn get_param(&self, idx: usize) -> f32 {
        self.params.get(idx)
    }

    pub fn set_param(&self, idx: usize, val: f32) {
        self.params.set(idx, val);
    }

    pub fn param_count(&self) -> usize {
        self.params.param_count()
    }

    /// See `EffectParams::snapshot`.
    pub fn snapshot(&self) -> (u32, Vec<f32>) {
        self.params.snapshot()
    }

    /// See `EffectParams::apply_snapshot`.
    pub fn apply_snapshot(&self, expected_version: u32, values: &[f32]) -> bool {
        self.params.apply_snapshot(expected_version, values)
    }
}
