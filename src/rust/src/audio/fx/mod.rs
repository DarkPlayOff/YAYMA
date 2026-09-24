//! Layers (not duplicates): DSP primitives (`biquad`/`delay`) <- effect
//! adapters (`modules::*`, wire `EffectParams` to primitives) <- registry and
//! RT slots (`chain`) <- UI views (`param::EffectHandle`). `init` registers
//! the default set; `MonitorEffect` stays separate (owned by controller).

use rodio::Source;

use foldhash::HashMap;
use std::{num::NonZero, time::Duration};

pub mod biquad;
pub mod chain;
pub mod delay;
pub mod init;
pub mod modules;
pub mod param;

pub use param::EffectHandle;

use chain::EffectChain;

const BUFFER_SIZE: usize = 512;

pub trait Effect: Send + 'static {
    fn process(&mut self, left: &mut [f32], right: &mut [f32]);

    fn reset(&mut self);
}

/// A source that can produce samples block-wise.
///
/// The default implementation pulls per sample; sources whose data arrives in
/// contiguous chunks (e.g. the streaming decoder bridge) override `read_chunk`
/// to fill via memcpy and only touch synchronization at chunk boundaries.
pub trait BlockSource: Source<Item = f32> {
    /// Fill `out` with samples; returns how many were written. Fewer than
    /// `out.len()` is returned only at end of stream — never manufacture
    /// silence to fill the block.
    fn read_chunk(&mut self, out: &mut [f32]) -> usize {
        let mut written = 0;
        while written < out.len() {
            match self.next() {
                Some(sample) => {
                    out[written] = sample;
                    written += 1;
                }
                None => break,
            }
        }
        written
    }
}

pub struct FxSource<T: BlockSource + Send + 'static> {
    inner: T,
    chain: EffectChain,
    buffer: [f32; BUFFER_SIZE],
    buffer_pos: usize,
    buffer_len: usize,
}

impl<T: BlockSource + Send + 'static> FxSource<T> {
    pub fn new(inner: T) -> Self {
        let channels = inner.channels().get();
        let sample_rate = inner.sample_rate().get();

        Self {
            inner,
            chain: EffectChain::new(channels, sample_rate),
            buffer: [0.0; BUFFER_SIZE],
            buffer_pos: 0,
            buffer_len: 0,
        }
    }

    pub fn add_effect(
        &mut self,
        id: &str,
        name: &str,
        effect: Box<dyn Effect>,
        params: std::sync::Arc<param::EffectParams>,
    ) -> EffectHandle {
        self.chain.add_effect(id, name, effect, params)
    }

    pub fn get_effect_handle(&self, name: &str) -> Option<&EffectHandle> {
        self.chain.get_handle(name)
    }

    pub fn get_effect_handles(&self) -> HashMap<String, EffectHandle> {
        self.chain.handles()
    }

    pub fn clear_effects(&mut self) {
        self.chain.clear();
    }

    #[inline(always)]
    fn fill_buffer(&mut self) -> bool {
        self.buffer_pos = 0;
        self.buffer_len = self.inner.read_chunk(&mut self.buffer);

        if self.buffer_len == 0 {
            return false;
        }

        self.chain.process_block(&mut self.buffer, self.buffer_len);

        true
    }
}

impl<T: BlockSource + Send + 'static> Source for FxSource<T> {
    fn current_span_len(&self) -> Option<usize> {
        self.inner.current_span_len()
    }

    fn channels(&self) -> NonZero<u16> {
        self.inner.channels()
    }

    fn sample_rate(&self) -> NonZero<u32> {
        self.inner.sample_rate()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.inner.total_duration()
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), rodio::source::SeekError> {
        let res = self.inner.try_seek(pos);
        if res.is_ok() {
            self.buffer_pos = 0;
            self.buffer_len = 0;
            self.chain.seek(pos);
        }
        res
    }
}

impl<T: BlockSource + Send + 'static> Iterator for FxSource<T> {
    type Item = f32;

    #[inline(always)]
    fn next(&mut self) -> Option<f32> {
        if self.buffer_pos >= self.buffer_len && !self.fill_buffer() {
            return None;
        }

        let sample = self.buffer[self.buffer_pos];
        self.buffer_pos += 1;
        Some(sample)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Minimal contiguous source used to exercise FxSource's block fill path.
    struct VecSource {
        samples: Vec<f32>,
        pos: usize,
    }

    impl VecSource {
        fn new(samples: Vec<f32>) -> Self {
            Self { samples, pos: 0 }
        }
    }

    impl Iterator for VecSource {
        type Item = f32;

        fn next(&mut self) -> Option<f32> {
            let s = self.samples.get(self.pos).copied();
            self.pos += 1;
            s
        }
    }

    impl Source for VecSource {
        fn current_span_len(&self) -> Option<usize> {
            None
        }
        fn channels(&self) -> std::num::NonZero<u16> {
            std::num::NonZero::new(2).unwrap()
        }
        fn sample_rate(&self) -> std::num::NonZero<u32> {
            std::num::NonZero::new(44100).unwrap()
        }
        fn total_duration(&self) -> Option<std::time::Duration> {
            None
        }
    }

    impl BlockSource for VecSource {}

    #[test]
    fn fx_source_passes_all_samples_through_block_fill() {
        let samples: Vec<f32> = (0..1000).map(|i| (i as f32 * 0.01).sin()).collect();
        let expected = samples.clone();

        let mut fx = FxSource::new(VecSource::new(samples));
        let drained: Vec<f32> = std::iter::from_fn(|| fx.next()).collect();

        assert_eq!(drained, expected);
        // End of stream must hold: no extra samples, no repeated blocks.
        assert_eq!(fx.next(), None);
        assert_eq!(fx.next(), None);
    }

    #[test]
    fn fx_source_applies_chain_to_partial_final_block() {
        // 600 samples with a 512-frame block: second block is partial (88),
        // gain must apply to exactly those 88 samples.
        let mut fx = FxSource::new(VecSource::new(vec![1.0; 600]));
        let params = Arc::new(param::EffectParams::new(&[]));
        params.set_enabled(true);
        fx.add_effect(
            "gain",
            "Gain",
            Box::new(GainEffect { gain: 0.5 }),
            params,
        );

        let drained: Vec<f32> = std::iter::from_fn(|| fx.next()).collect();
        assert_eq!(drained.len(), 600);
        assert!(drained.iter().all(|&v| v == 0.5));
    }

    struct GainEffect {
        gain: f32,
    }

    impl Effect for GainEffect {
        fn process(&mut self, left: &mut [f32], right: &mut [f32]) {
            for (l, r) in left.iter_mut().zip(right.iter_mut()) {
                *l *= self.gain;
                *r *= self.gain;
            }
        }

        fn reset(&mut self) {}
    }
}
