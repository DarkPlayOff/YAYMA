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

pub struct EffectParams {
    enabled: AtomicBool,
    values: Vec<AtomicF32>,
    info: Vec<ParamInfo>,
}

unsafe impl Send for EffectParams {}
unsafe impl Sync for EffectParams {}

impl EffectParams {
    pub fn new(info: &[ParamInfo]) -> Self {
        Self {
            enabled: AtomicBool::new(false),
            values: info.iter().map(|p| AtomicF32::new(p.default)).collect(),
            info: info.to_vec(),
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
        } else {
            debug_assert!(false, "EffectParams::set OOB index {idx}");
        }
    }

    pub fn param_count(&self) -> usize {
        self.values.len()
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
}
