use foldhash::HashMap;
use foldhash::HashMapExt;
use std::sync::Arc;
use std::time::Duration;

use super::Effect;
use super::param::{EffectHandle, EffectParams};

struct EffectSlot {
    #[allow(dead_code)]
    id: String,
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
        Self {
            slots: Vec::new(),
            handles: HashMap::new(),
            channels: channels as usize,
            left: Vec::new(),
            right: Vec::new(),
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
        self.slots.push(EffectSlot {
            id: id_str,
            effect,
            params,
        });

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
        if self.slots.is_empty() || len == 0 || self.channels < 2 {
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

        if self.left.capacity() < frames {
            self.left.reserve(frames - self.left.capacity());
        }
        if self.right.capacity() < frames {
            self.right.reserve(frames - self.right.capacity());
        }

        unsafe {
            self.left.set_len(frames);
            self.right.set_len(frames);
        }

        for i in 0..frames {
            let base = i * ch;
            self.left[i] = buffer[base];
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
