use foldhash::HashMap;
use foldhash::HashMapExt;
use std::sync::Arc;
use std::time::Duration;

use super::Effect;
use super::param::{EffectHandle, EffectParams};

/// RT slot: DSP effect plus its shared params. The audio thread touches only
/// this; `process_block` must never block or allocate (scratch lives in
/// `EffectChain`, preallocated via `new`/`ensure_capacity`).
struct EffectSlot {
    effect: Box<dyn Effect>,
    params: Arc<EffectParams>,
}

/// Registry + slots layer: owns DSP slots and the id->`EffectHandle` map.
/// Adapters (`modules::*`) do DSP; primitives (`super::biquad/delay`) do math.
pub struct EffectChain {
    slots: Vec<EffectSlot>,
    handles: HashMap<String, EffectHandle>,
    channels: usize,
    left: Vec<f32>,
    right: Vec<f32>,
}

impl EffectChain {
    pub fn new(channels: u16, _sample_rate: u32) -> Self {
        // Preallocate scratch buffers outside the realtime callback
        // to avoid heap allocation in process_block hot path.
        const INITIAL_FRAMES: usize = 2048;
        Self {
            slots: Vec::new(),
            handles: HashMap::new(),
            channels: channels as usize,
            left: vec![0.0; INITIAL_FRAMES],
            right: vec![0.0; INITIAL_FRAMES],
        }
    }

    /// Ensure scratch capacity without allocating in the audio thread if possible.
    pub fn ensure_capacity(&mut self, frames: usize) {
        if self.left.len() < frames {
            self.left.resize(frames, 0.0);
        }
        if self.right.len() < frames {
            self.right.resize(frames, 0.0);
        }
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    pub fn add_effect(
        &mut self,
        id: &str,
        name: &str,
        effect: Box<dyn Effect>,
        params: Arc<EffectParams>,
    ) -> EffectHandle {
        let id_str = id.to_string();
        let handle = EffectHandle {
            id: id_str.clone(),
            name: name.to_string(),
            params: params.clone(),
        };

        self.handles.insert(id_str.clone(), handle.clone());
        self.slots.push(EffectSlot { effect, params });

        handle
    }

    pub fn handles(&self) -> HashMap<String, EffectHandle> {
        self.handles.clone()
    }

    pub fn get_handle(&self, id: &str) -> Option<&EffectHandle> {
        self.handles.get(id)
    }

    #[inline]
    pub fn process_block(&mut self, buffer: &mut [f32], len: usize) {
        if self.slots.is_empty() || len == 0 || self.channels == 0 {
            return;
        }

        let ch = self.channels;
        let frames = len / ch;
        if frames == 0 {
            return;
        }

        let any_enabled = self.slots.iter().any(|s| s.params.is_enabled());
        if !any_enabled {
            return;
        }

        debug_assert!(
            self.left.len() >= frames && self.right.len() >= frames,
            "EffectChain scratch under capacity: have {}/{}, need {frames}",
            self.left.len(),
            self.right.len()
        );
        // Fallback path only: avoid unsafe set_len; resize keeps init memory.
        if self.left.len() < frames {
            self.left.resize(frames, 0.0);
        }
        if self.right.len() < frames {
            self.right.resize(frames, 0.0);
        }

        if ch == 1 {
            // Mono: run effects on duplicated mono so monitor/fade/FX keep working.
            for i in 0..frames {
                let m = buffer[i];
                self.left[i] = m;
                self.right[i] = m;
            }

            for slot in &mut self.slots {
                if slot.params.is_enabled() {
                    slot.effect
                        .process(&mut self.left[..frames], &mut self.right[..frames]);
                }
            }

            for i in 0..frames {
                buffer[i] = 0.5 * (self.left[i] + self.right[i]);
            }
            return;
        }

        for i in 0..frames {
            let base = i * ch;
            self.left[i] = buffer[base];
            // For >2 channels process first two, rest pass through untouched.
            self.right[i] = buffer[base + 1];
        }

        for slot in &mut self.slots {
            if slot.params.is_enabled() {
                slot.effect
                    .process(&mut self.left[..frames], &mut self.right[..frames]);
            }
        }

        for i in 0..frames {
            let base = i * ch;
            buffer[base] = self.left[i];
            buffer[base + 1] = self.right[i];
        }
    }

    pub fn seek(&mut self, _pos: Duration) {
        for slot in &mut self.slots {
            slot.effect.reset();
        }
    }

    pub fn clear(&mut self) {
        self.slots.clear();
        self.handles.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::fx::param::ParamInfo;

    struct GainEffect {
        gain: f32,
    }

    impl super::super::Effect for GainEffect {
        fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
            for (l, r) in left.iter_mut().zip(right.iter_mut()) {
                *l *= self.gain;
                *r *= self.gain;
            }
        }

        fn reset(&mut self) {}
    }

    fn chain_with_gain(channels: u16, gain: f32, enabled: bool) -> EffectChain {
        let mut chain = EffectChain::new(channels, 44100);
        let params = Arc::new(EffectParams::new(&[ParamInfo {
            name: "gain",
            min: 0.0,
            max: 4.0,
            default: 1.0,
            step: 0.1,
            unit: "",
        }]));
        params.set_enabled(enabled);
        chain.add_effect(
            "gain",
            "Gain",
            Box::new(GainEffect { gain }),
            params,
        );
        chain
    }

    #[test]
    fn empty_chain_leaves_buffer_untouched() {
        let mut chain = EffectChain::new(2, 44100);
        let mut buf = vec![0.5f32; 8];
        let snapshot = buf.clone();
        chain.process_block(&mut buf, 8);
        assert_eq!(buf, snapshot);
    }

    #[test]
    fn stereo_effect_processes_both_channels() {
        let mut chain = chain_with_gain(2, 2.0, true);
        // L/R interleaved: [l0, r0, l1, r1]
        let mut buf = vec![0.25, 0.5, 0.25, 0.5];
        chain.process_block(&mut buf, 4);
        assert_eq!(buf, vec![0.5, 1.0, 0.5, 1.0]);
    }

    #[test]
    fn disabled_effect_is_skipped() {
        let mut chain = chain_with_gain(2, 2.0, false);
        let mut buf = vec![0.25, 0.5, 0.25, 0.5];
        let snapshot = buf.clone();
        chain.process_block(&mut buf, 4);
        assert_eq!(buf, snapshot);
    }

    #[test]
    fn mono_tracks_go_through_effects() {
        // Regression test: mono used to bypass the whole chain.
        let mut chain = chain_with_gain(1, 2.0, true);
        let mut buf = vec![0.25, 0.25, 0.25, 0.25];
        chain.process_block(&mut buf, 4);
        assert_eq!(buf, vec![0.5, 0.5, 0.5, 0.5]);
    }

    #[test]
    fn extra_channels_pass_through_untouched() {
        let mut chain = chain_with_gain(4, 2.0, true);
        let mut buf = vec![0.25, 0.5, 0.75, 1.0];
        chain.process_block(&mut buf, 4);
        assert_eq!(buf, vec![0.5, 1.0, 0.75, 1.0]);
    }
}
