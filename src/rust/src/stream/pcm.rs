use crate::audio::progress::TrackProgress;
use crossbeam_channel::{
    Receiver as CbReceiver, Sender as CbSender, TryRecvError, bounded as cb_bounded, select,
};
use rodio::{Decoder, Source};
use std::num::NonZero;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use std::thread;
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const PCM_CHUNK_SAMPLES: usize = 16384;

const SAMPLE_CHANNEL_CAPACITY: usize = 64;

enum SampleMessage {
    Samples(Vec<f32>, u64),
    Finished(u64),
}

enum DecoderCommand {
    Seek { position: Duration, generation: u64 },
    Stop,
}

#[derive(Clone)]
pub struct StreamController {
    cmd_tx: CbSender<DecoderCommand>,
    generation: Arc<AtomicU64>,
}

impl StreamController {
    pub fn seek(&self, position: Duration) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let _ = self.cmd_tx.send(DecoderCommand::Seek {
            position,
            generation,
        });
    }

    pub fn stop(&self) {
        let _ = self.cmd_tx.send(DecoderCommand::Stop);
    }
}

pub struct BufferedStreamingSource {
    rx: CbReceiver<SampleMessage>,
    recycle_tx: CbSender<Vec<f32>>,
    pending_samples: Vec<f32>,
    sample_pos: usize,
    pending_generation: u64,
    generation: Arc<AtomicU64>,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    finished_generation: Option<u64>,
    controller: StreamController,
}

impl Drop for BufferedStreamingSource {
    fn drop(&mut self) {
        // Ensure the decoder loop exits as soon as it reaches its command
        // checkpoint after a skipped track, instead of waiting for another
        // source read or seek request.
        self.controller.stop();
    }
}

impl BufferedStreamingSource {
    fn recycle_current(&mut self) {
        if self.pending_samples.capacity() > 0 {
            let old = std::mem::take(&mut self.pending_samples);
            let _ = self.recycle_tx.try_send(old);
        }
    }

    /// Make at least one sample of the current generation available at
    /// `sample_pos`; returns false only at end of stream. Blocks (with a
    /// timeout) while the network source is buffering, without manufacturing
    /// silence. Generation is re-checked here — i.e. only when the current
    /// chunk is exhausted or was cleared by `try_seek`, never per sample:
    /// seeks always clear `pending_samples` first, so a mid-chunk generation
    /// bump cannot happen.
    fn refill_if_needed(&mut self) -> bool {
        loop {
            let current_generation = self.generation.load(Ordering::Acquire);
            if self.pending_generation != current_generation {
                self.pending_generation = current_generation;
                self.recycle_current();
                self.sample_pos = 0;
                self.finished_generation = None;
            }

            if self.sample_pos < self.pending_samples.len() {
                return true;
            }

            if let Some(finished_gen) = self.finished_generation
                && finished_gen == current_generation
            {
                return false;
            }

            match self.rx.try_recv() {
                Ok(SampleMessage::Samples(samples, msg_gen)) => {
                    if msg_gen != current_generation {
                        let _ = self.recycle_tx.try_send(samples);
                        continue;
                    }
                    self.recycle_current();
                    self.pending_samples = samples;
                    self.sample_pos = 0;
                    continue;
                }
                Ok(SampleMessage::Finished(msg_gen)) => {
                    if msg_gen == current_generation {
                        self.finished_generation = Some(msg_gen);
                        return false;
                    }
                    continue;
                }
                Err(TryRecvError::Empty) => {
                    // Wait with a timeout so seek/stop (generation bump) wakes
                    // us even when the decoder is stalled; the loop head
                    // re-checks the generation on every wake-up.
                    match self.rx.recv_timeout(Duration::from_millis(150)) {
                        Ok(SampleMessage::Samples(samples, msg_gen)) => {
                            if msg_gen != current_generation {
                                let _ = self.recycle_tx.try_send(samples);
                                continue;
                            }
                            self.recycle_current();
                            self.pending_samples = samples;
                            self.sample_pos = 0;
                            continue;
                        }
                        Ok(SampleMessage::Finished(msg_gen)) => {
                            if msg_gen == current_generation {
                                self.finished_generation = Some(msg_gen);
                                return false;
                            }
                            continue;
                        }
                        Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
                        Err(crossbeam_channel::RecvTimeoutError::Disconnected) => return false,
                    }
                }
                Err(TryRecvError::Disconnected) => return false,
            }
        }
    }

    fn new(
        rx: CbReceiver<SampleMessage>,
        recycle_tx: CbSender<Vec<f32>>,
        generation: Arc<AtomicU64>,
        sample_rate: u32,
        channels: u16,
        total_duration: Option<Duration>,
        controller: StreamController,
    ) -> Self {
        let pending_generation = generation.load(Ordering::SeqCst);
        Self {
            rx,
            recycle_tx,
            pending_samples: Vec::new(),
            sample_pos: 0,
            pending_generation,
            generation,
            sample_rate,
            channels,
            total_duration,
            finished_generation: None,
            controller,
        }
    }
}

impl Iterator for BufferedStreamingSource {
    type Item = f32;

    fn next(&mut self) -> Option<f32> {
        if self.sample_pos >= self.pending_samples.len() && !self.refill_if_needed() {
            return None;
        }
        let sample = self.pending_samples[self.sample_pos];
        self.sample_pos += 1;
        Some(sample)
    }
}

impl crate::audio::fx::BlockSource for BufferedStreamingSource {
    /// Audio-thread hot path: fills `out` with memcpy from the current
    /// decoder chunk, touching the channel and generation only at chunk
    /// boundaries (~every 16384 samples).
    fn read_chunk(&mut self, out: &mut [f32]) -> usize {
        let mut written = 0;
        while written < out.len() && self.refill_if_needed() {
            let available = self.pending_samples.len() - self.sample_pos;
            let wanted = out.len() - written;
            let n = available.min(wanted);
            out[written..written + n]
                .copy_from_slice(&self.pending_samples[self.sample_pos..self.sample_pos + n]);
            self.sample_pos += n;
            written += n;
        }
        written
    }
}

impl Source for BufferedStreamingSource {
    fn current_span_len(&self) -> Option<usize> {
        None
    }

    fn channels(&self) -> NonZero<u16> {
        NonZero::new(self.channels).unwrap()
    }

    fn sample_rate(&self) -> NonZero<u32> {
        NonZero::new(self.sample_rate).unwrap()
    }

    fn total_duration(&self) -> Option<Duration> {
        self.total_duration
    }

    fn try_seek(&mut self, pos: Duration) -> std::result::Result<(), rodio::source::SeekError> {
        self.recycle_current();
        self.sample_pos = 0;
        self.finished_generation = None;
        self.controller.seek(pos);
        Ok(())
    }
}

pub struct StreamingSession {
    pub source: BufferedStreamingSource,
    pub controller: StreamController,
    pub codec: String,
}

pub fn create_streaming_session<R: std::io::Read + std::io::Seek + Send + Sync + 'static>(
    data_source: R,
    total_bytes: u64,
    codec: String,
    progress: Arc<TrackProgress>,
) -> Result<StreamingSession> {
    let decoder = Decoder::builder()
        .with_data(data_source)
        .with_hint(codec.as_str())
        .with_byte_len(total_bytes)
        .with_coarse_seek(true)
        .with_gapless(true)
        .build()
        .map_err(|err| Box::<dyn std::error::Error + Send + Sync>::from(err.to_string()))?;

    let sample_rate = decoder.sample_rate();
    let channels = decoder.channels();
    let total_duration = decoder.total_duration();
    if let Some(total) = total_duration {
        progress.set_total_duration(total);
    }

    let (sample_tx, sample_rx) = cb_bounded::<SampleMessage>(SAMPLE_CHANNEL_CAPACITY);
    let (recycle_tx, recycle_rx) = cb_bounded::<Vec<f32>>(SAMPLE_CHANNEL_CAPACITY + 2);
    let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded::<DecoderCommand>();
    let generation = Arc::new(AtomicU64::new(0));
    let controller = StreamController {
        cmd_tx,
        generation: generation.clone(),
    };

    let decoder_generation = generation.clone();
    let progress_clone = Arc::clone(&progress);
    let progress_generation = progress.get_generation();
    thread::Builder::new()
        .name("yamusic-stream".into())
        .spawn(move || {
            run_decode_loop(
                decoder,
                sample_tx,
                cmd_rx,
                recycle_rx,
                decoder_generation,
                progress_clone,
                progress_generation,
            );
        })
        .map_err(|err| Box::<dyn std::error::Error + Send + Sync>::from(err.to_string()))?;

    let source = BufferedStreamingSource::new(
        sample_rx,
        recycle_tx,
        generation,
        sample_rate.get(),
        channels.get(),
        total_duration,
        controller.clone(),
    );

    Ok(StreamingSession {
        source,
        controller,
        codec,
    })
}

fn run_decode_loop<R: std::io::Read + std::io::Seek + Send + Sync + 'static>(
    mut decoder: Decoder<R>,
    sample_tx: CbSender<SampleMessage>,
    cmd_rx: CbReceiver<DecoderCommand>,
    recycle_rx: CbReceiver<Vec<f32>>,
    generation: Arc<AtomicU64>,
    progress: Arc<TrackProgress>,
    progress_generation: u64,
) {
    let mut active_generation = generation.load(Ordering::Acquire);

    let get_buffer = || match recycle_rx.try_recv() {
        Ok(mut v) => {
            v.clear();
            v
        }
        Err(_) => Vec::with_capacity(PCM_CHUNK_SAMPLES),
    };

    let mut chunk = get_buffer();
    let mut pending_chunk: Option<Vec<f32>> = None;

    loop {
        loop {
            match cmd_rx.try_recv() {
                Ok(DecoderCommand::Seek {
                    position,
                    generation: new_gen,
                }) => {
                    if let Err(e) = decoder.try_seek(position) {
                        tracing::warn!(error = %e, "decoder coarse seek failed");
                    }
                    if progress_generation == progress.get_generation() {
                        progress.set_current_position(position);
                    }
                    active_generation = new_gen;
                    if let Some(mut pc) = pending_chunk.take() {
                        pc.clear();
                        chunk = pc;
                    }
                }
                Ok(DecoderCommand::Stop) => return,
                Err(crossbeam_channel::TryRecvError::Empty) => break,
                Err(crossbeam_channel::TryRecvError::Disconnected) => return,
            }
        }

        if let Some(chunk_to_send) = pending_chunk.take() {
            select! {
                send(sample_tx, SampleMessage::Samples(chunk_to_send, active_generation)) -> res => {
                    if res.is_err() {
                        return;
                    }
                }
                recv(cmd_rx) -> msg => {
                    match msg {
                        Ok(DecoderCommand::Seek { position, generation: new_gen }) => {
                            if let Err(e) = decoder.try_seek(position) {
                                tracing::warn!(error = %e, "decoder coarse seek failed");
                            }
                            if progress_generation == progress.get_generation() {
                                progress.set_current_position(position);
                            }
                            active_generation = new_gen;
                            if let Some(mut pc) = pending_chunk.take() {
                                pc.clear();
                                chunk = pc;
                            }
                            continue;
                        }
                        Ok(DecoderCommand::Stop) => return,
                        Err(_) => return,
                    }
                }
            }
        }

        chunk.clear();
        for _ in 0..PCM_CHUNK_SAMPLES {
            match decoder.next() {
                Some(sample) => chunk.push(sample),
                None => break,
            }
        }

        if chunk.is_empty() {
            if sample_tx
                .send(SampleMessage::Finished(active_generation))
                .is_err()
            {
                return;
            }
            // Stay alive: wait for a Seek command to restart decoding
            // or a Stop command to exit cleanly
            match cmd_rx.recv() {
                Ok(DecoderCommand::Seek {
                    position,
                    generation: new_gen,
                }) => {
                    if let Err(e) = decoder.try_seek(position) {
                        tracing::warn!(error = %e, "decoder coarse seek failed");
                    }
                    if progress_generation == progress.get_generation() {
                        progress.set_current_position(position);
                    }
                    active_generation = new_gen;
                    if let Some(mut pc) = pending_chunk.take() {
                        pc.clear();
                        chunk = pc;
                    }
                    continue;
                }
                Ok(DecoderCommand::Stop) | Err(_) => return,
            }
        }

        let new_chunk = get_buffer();
        let send_chunk = std::mem::replace(&mut chunk, new_chunk);

        match sample_tx.try_send(SampleMessage::Samples(send_chunk, active_generation)) {
            Ok(()) => {}
            Err(crossbeam_channel::TrySendError::Full(msg)) => {
                if let SampleMessage::Samples(chunk_data, _) = msg {
                    pending_chunk = Some(chunk_data);
                }
            }
            Err(crossbeam_channel::TrySendError::Disconnected(_)) => {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::fx::BlockSource;
    use std::sync::Arc;

    /// A BufferedStreamingSource wired to test channels — no decoder needed.
    struct TestRig {
        source: BufferedStreamingSource,
        sample_tx: CbSender<SampleMessage>,
        controller: StreamController,
        generation: Arc<AtomicU64>,
    }

    fn make_rig() -> TestRig {
        let (sample_tx, sample_rx) = cb_bounded::<SampleMessage>(SAMPLE_CHANNEL_CAPACITY);
        let (recycle_tx, _recycle_rx) = cb_bounded::<Vec<f32>>(SAMPLE_CHANNEL_CAPACITY + 2);
        // No decoder loop in tests: commands are dropped (sends are ignored
        // by StreamController), only the generation bump matters.
        let (cmd_tx, _cmd_rx) = crossbeam_channel::unbounded::<DecoderCommand>();
        let generation = Arc::new(AtomicU64::new(0));
        let controller = StreamController {
            cmd_tx,
            generation: generation.clone(),
        };
        let source = BufferedStreamingSource::new(
            sample_rx,
            recycle_tx,
            generation.clone(),
            44100,
            2,
            None,
            controller.clone(),
        );
        TestRig {
            source,
            sample_tx,
            controller,
            generation,
        }
    }

    #[test]
    fn read_chunk_spans_decoder_chunk_boundaries() {
        let mut rig = make_rig();
        let chunk_a: Vec<f32> = (0..1000).map(|i| i as f32).collect();
        let chunk_b: Vec<f32> = (1000..2000).map(|i| i as f32).collect();
        rig.sample_tx
            .send(SampleMessage::Samples(chunk_a, 0))
            .unwrap();
        rig.sample_tx
            .send(SampleMessage::Samples(chunk_b, 0))
            .unwrap();

        // A block larger than one decoder chunk must be filled in one call,
        // stitching consecutive chunks seamlessly.
        let expected_a: Vec<f32> = (0..1000).map(|i| i as f32).collect();
        let mut out = [0.0f32; 1500];
        assert_eq!(rig.source.read_chunk(&mut out), 1500);
        assert_eq!(&out[..1000], &expected_a[..]);
        assert_eq!(out[1000], 1000.0);
        assert_eq!(out[1499], 1499.0);

        // Remaining samples continue from where the last read stopped.
        let mut tail = [0.0f32; 500];
        assert_eq!(rig.source.read_chunk(&mut tail), 500);
        assert_eq!(tail[0], 1500.0);
        assert_eq!(tail[499], 1999.0);
    }

    #[test]
    fn read_chunk_returns_partial_only_at_end_of_stream() {
        let mut rig = make_rig();
        rig.sample_tx
            .send(SampleMessage::Samples(vec![1.0; 300], 0))
            .unwrap();
        rig.sample_tx.send(SampleMessage::Finished(0)).unwrap();

        // Stream ends mid-block: return what exists, then stay at 0 (no
        // manufactured silence).
        let mut out = [0.0f32; 512];
        assert_eq!(rig.source.read_chunk(&mut out), 300);
        assert!(out[..300].iter().all(|&v| v == 1.0));
        assert_eq!(rig.source.read_chunk(&mut out), 0);
        assert_eq!(rig.source.read_chunk(&mut out), 0);
    }

    #[test]
    fn read_chunk_waits_for_first_sample() {
        let mut rig = make_rig();
        let mut out = [0.0f32; 8];

        // No data yet: read_chunk must wait (bounded by recv timeouts), which
        // we verify by racing a late send.
        let tx = rig.sample_tx.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            let _ = tx.send(SampleMessage::Samples(vec![7.0; 8], 0));
        });
        assert_eq!(rig.source.read_chunk(&mut out), 8);
        assert!(out.iter().all(|&v| v == 7.0));
    }

    #[test]
    fn read_chunk_skips_stale_generation_chunks() {
        let mut rig = make_rig();
        // Stale chunk in flight (tagged with generation 0)...
        rig.sample_tx
            .send(SampleMessage::Samples(vec![0.0; 64], 0))
            .unwrap();
        // ...a seek bumps the generation and clears pending...
        rig.controller.seek(Duration::from_millis(1000));
        assert_ne!(rig.generation.load(Ordering::Acquire), 0);
        // ...and the decoder delivers the new generation's chunk.
        rig.sample_tx
            .send(SampleMessage::Samples(vec![1.0; 64], 1))
            .unwrap();

        let mut out = [0.0f32; 64];
        assert_eq!(rig.source.read_chunk(&mut out), 64);
        assert!(
            out.iter().all(|&v| v == 1.0),
            "stale-generation samples must never be emitted"
        );
    }

    #[test]
    fn next_and_read_chunk_share_cursor() {
        let mut rig = make_rig();
        rig.sample_tx
            .send(SampleMessage::Samples((0..10).map(|i| i as f32).collect(), 0))
            .unwrap();

        assert_eq!(rig.source.next(), Some(0.0));
        let mut out = [0.0f32; 3];
        assert_eq!(rig.source.read_chunk(&mut out), 3);
        assert_eq!(out, [1.0, 2.0, 3.0]);
        assert_eq!(rig.source.next(), Some(4.0));
    }
}
