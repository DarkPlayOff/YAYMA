use foldhash::HashMap;
use foldhash::HashMapExt;
use std::sync::Arc;
use std::time::Duration;

use super::Effect;
use super::param::{EffectHandle, EffectParams};

struct EffectSlot {
    effect: Box<dyn Effect>,
    params: Arc<EffectParams>,
}

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
