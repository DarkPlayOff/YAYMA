use crate::audio::progress::TrackProgress;
use crate::util::reactive::Signal;
use flume::{Receiver, Sender};
use parking_lot::Mutex;
use reqwest::Client;
use std::io::{Read, Seek, SeekFrom};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use std::time::Duration;

use super::buffer::BufferState;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const DEFAULT_PREFETCH_SIZE: usize = 1024 * 1024;
const MIN_INITIAL_DATA: usize = 128 * 1024;
const MAX_ATTEMPTS: usize = 30; // Fewer attempts but longer wait

enum FetchCommand {
    Fetch {
        start: u64,
        end: u64,
        generation: u64,
    },
    Shutdown,
}

pub struct StreamingDataSource {
    total_bytes: u64,
    buffer: Arc<Mutex<BufferState>>,
    position: Arc<AtomicU64>,
    generation: Arc<AtomicU64>,
    fetch_tx: Sender<FetchCommand>,
    fetch_rx: Receiver<()>,
    task_handle: Option<tokio::task::JoinHandle<()>>,
    buffering_signal: Option<Signal<bool>>,
    prefetch_size: usize,
}

impl StreamingDataSource {
    pub async fn new(
        client: Client,
        url: String,
        progress: Arc<TrackProgress>,
        buffering_signal: Option<Signal<bool>>,
        duration_ms: Option<u64>,
    ) -> Result<Self> {
        let progress_generation = progress.get_generation();

        // 1. Fetch first chunk to get total content size
        let range_header = format!("bytes=0-{}", DEFAULT_PREFETCH_SIZE - 1);
        let resp = client
            .get(&url)
            .header("Range", range_header)
            .send()
            .await?;

        let total = if let Some(range) = resp.headers().get("content-range") {
            let s = range.to_str().map_err(|_| {
                Box::<dyn std::error::Error + Send + Sync>::from("invalid content-range header")
            })?;
            if let Some(slash) = s.find('/') {
                s[slash + 1..].parse::<u64>().map_err(|_| {
                    Box::<dyn std::error::Error + Send + Sync>::from(
                        "invalid total size in content-range",
                    )
                })?
            } else {
                return Err(Box::<dyn std::error::Error + Send + Sync>::from(
                    "invalid content-range format",
                ));
            }
        } else {
            resp.content_length().ok_or_else(|| {
                Box::<dyn std::error::Error + Send + Sync>::from("content-length missing")
            })?
        };

        progress.set_total_bytes(total);

        // 2. Calculate dynamic buffer sizes based on bit rate
        // We target: 
        // - BUFFER_SIZE = 30 seconds of audio
        // - PREFETCH_TRIGGER = 15 seconds of audio
        // - PREFETCH_SIZE = 10 seconds of audio
        let (buffer_size, prefetch_trigger, prefetch_size) = if let Some(dur_ms) = duration_ms && dur_ms > 0 {
            let bytes_per_ms = total as f64 / dur_ms as f64;
            let buf_size = (30_000.0 * bytes_per_ms) as usize;
            let trigger = (15_000.0 * bytes_per_ms) as usize;
            let fetch = (10_000.0 * bytes_per_ms) as usize;

            // Clamping to reasonable bounds:
            // buffer_size: min 4MB, max 32MB
            // prefetch_trigger: min 256KB, max 4MB
            // prefetch_size: min 512KB, max 4MB
            (
                buf_size.clamp(4 * 1024 * 1024, 32 * 1024 * 1024),
                trigger.clamp(256 * 1024, 4 * 1024 * 1024),
                fetch.clamp(512 * 1024, 4 * 1024 * 1024),
            )
        } else {
            // Default constants if duration is missing
            (
                8 * 1024 * 1024,
                256 * 1024,
                1024 * 1024,
            )
        };

        let initial_data = resp.bytes().await?;

        let buffer = Arc::new(Mutex::new(BufferState::new(total, buffer_size, prefetch_trigger)));
        {
            let mut b = buffer.lock();
            b.append(initial_data, 0);
        }

        progress.set_buffered_bytes({
            let b = buffer.lock();
            b.max_buffered_from_start()
        });

        let position = Arc::new(AtomicU64::new(0));
        let (tx_cmd, rx_cmd) = flume::unbounded();
        let (tx_res, rx_res) = flume::unbounded();
        let generation = Arc::new(AtomicU64::new(0));

        let tx_res_clone = tx_res.clone();
        let generation_clone = Arc::clone(&generation);

        let context = FetchContext {
            client,
            url: url.clone(),
            buffer: Arc::clone(&buffer),
            progress: Arc::clone(&progress),
            generation: generation_clone,
            rx_cmd,
            tx_res: tx_res_clone,
            progress_generation,
        };

        let task_handle = {
            tokio::spawn(async move {
                Self::fetch_loop_async(context).await;
            })
        };

        let src = Self {
            total_bytes: total,
            buffer,
            position,
            generation,
            fetch_tx: tx_cmd,
            fetch_rx: rx_res,
            task_handle: Some(task_handle),
            buffering_signal,
            prefetch_size,
        };

        src.wait_for(0, MIN_INITIAL_DATA)?;
        Ok(src)
    }

    async fn fetch_loop_async(ctx: FetchContext) {
        while let Ok(cmd) = ctx.rx_cmd.recv_async().await {
            match cmd {
                FetchCommand::Fetch {
                    start,
                    end,
                    generation: request_generation,
                } => {
                    {
                        let mut buf = ctx.buffer.lock();
                        buf.mark_pending(start, end);
                    }
                    match Self::fetch_range_async(&ctx.client, &ctx.url, start, end).await {
                        Ok(data) => {
                            if request_generation != ctx.generation.load(Ordering::Acquire) {
                                let _ = ctx.tx_res.send(());
                                continue;
                            }

                            let maybe_buffered = {
                                let mut buf = ctx.buffer.lock();
                                if buf.append(data, start) {
                                    Some(buf.max_buffered_from_start())
                                } else {
                                    None
                                }
                            };

                            if request_generation == ctx.generation.load(Ordering::Acquire)
                                && ctx.progress_generation == ctx.progress.get_generation()
                                && let Some(buffered_pos) = maybe_buffered
                            {
                                ctx.progress.set_buffered_bytes(buffered_pos);
                            }
                            let _ = ctx.tx_res.send(());
                        }
                        Err(err) => {
                            let mut buf = ctx.buffer.lock();
                            buf.clear_pending();
                            let _ = ctx.tx_res.send(());
                            eprintln!("fetch_range_async error: {:?}", err);
                        }
                    }
                }
                FetchCommand::Shutdown => {
                    break;
                }
            }
        }
    }

    async fn fetch_range_async(
        client: &Client,
        url: &str,
        start: u64,
        end: u64,
    ) -> Result<bytes::Bytes> {
        let hdr = format!("bytes={}-{}", start, end.saturating_sub(1));
        let resp = client.get(url).header("Range", hdr).send().await?;
        Ok(resp.bytes().await?)
    }

    fn fetch(&self, start: u64, size: u64) -> Result<()> {
        let end = (start + size).min(self.total_bytes);
        let generation = self.generation.load(Ordering::Acquire);
        self.fetch_tx
            .send(FetchCommand::Fetch {
                start,
                end,
                generation,
            })
            .map_err(|_| Box::<dyn std::error::Error + Send + Sync>::from("fetch cmd failed"))
    }

    fn wait_for(&self, pos: u64, min: usize) -> Result<()> {
        {
            let buf = self.buffer.lock();
            if buf.available_from(pos) >= min || buf.eof {
                return Ok(());
            }
        }

        if let Some(sig) = &self.buffering_signal {
            sig.set(true);
        }

        let mut attempts = 0usize;
        let mut result = Ok(());

        while attempts < MAX_ATTEMPTS {
            // Wait for next fetch completion with a longer timeout
            match self.fetch_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(_) => {
                    let buf = self.buffer.lock();
                    if buf.available_from(pos) >= min || buf.eof {
                        break;
                    }
                    // Reset attempts because we received a notification, even if it didn't satisfy our range
                    attempts = 0;
                }
                Err(flume::RecvTimeoutError::Timeout) => {
                    attempts += 1;
                }
                Err(_) => {
                    result = Err("fetch channel closed".into());
                    break;
                }
            }
        }

        if attempts >= MAX_ATTEMPTS {
            result = Err("wait_for_data timed out".into());
        }

        if let Some(sig) = &self.buffering_signal {
            sig.set(false);
        }

        result
    }

    fn ensure(&self, pos: u64) -> Result<()> {
        {
            let buf = self.buffer.lock();
            if buf.contains(pos) {
                return Ok(());
            }
        }

        let _ = self.generation.fetch_add(1, Ordering::Release);
        {
            let mut buf = self.buffer.lock();
            buf.clear(pos);
        }

        let size = self.prefetch_size
            .max(MIN_INITIAL_DATA)
            .min((self.total_bytes.saturating_sub(pos)) as usize) as u64;
        if size > 0 {
            self.fetch(pos, size)?;
            self.wait_for(pos, MIN_INITIAL_DATA.min(size as usize))?;
        }

        Ok(())
    }

    fn trigger_prefetch(&self) {
        let (should, start, size) = {
            let pos = self.position.load(Ordering::Relaxed);
            let buf = self.buffer.lock();
            if buf.should_prefetch(pos) {
                let start = buf.end_pos();
                let size = self.prefetch_size.min((self.total_bytes.saturating_sub(start)) as usize);
                (size > 0, start, size)
            } else {
                (false, 0, 0)
            }
        };
        if should {
            let generation = self.generation.load(Ordering::Acquire);
            let _ = self.fetch_tx.try_send(FetchCommand::Fetch {
                start,
                end: start + size as u64,
                generation,
            });
        }
    }

    pub fn total_bytes(&self) -> u64 {
        self.total_bytes
    }
}

struct FetchContext {
    client: Client,
    url: String,
    buffer: Arc<Mutex<BufferState>>,
    progress: Arc<TrackProgress>,
    generation: Arc<AtomicU64>,
    rx_cmd: Receiver<FetchCommand>,
    tx_res: Sender<()>,
    progress_generation: u64,
}

impl Read for StreamingDataSource {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let pos = self.position.load(Ordering::Relaxed);
        if pos >= self.total_bytes {
            return Ok(0);
        }

        let has = {
            let b = self.buffer.lock();
            b.contains(pos)
        };

        if !has {
            self.ensure(pos).map_err(std::io::Error::other)?;
        }

        let bytes = {
            let mut b = self.buffer.lock();
            let read = b.read_at(pos, buf);
            if read > 0 {
                b.discard_before(pos.saturating_add(read as u64));
            }
            read
        };

        if bytes > 0 {
            self.position.fetch_add(bytes as u64, Ordering::Relaxed);
            self.trigger_prefetch();
        }

        Ok(bytes)
    }
}

impl Seek for StreamingDataSource {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        let new = match from {
            SeekFrom::Start(o) => o,
            SeekFrom::End(off) => {
                if off >= 0 {
                    self.total_bytes.saturating_add(off as u64)
                } else {
                    self.total_bytes.saturating_sub((-off) as u64)
                }
            }
            SeekFrom::Current(off) => {
                let cur = self.position.load(Ordering::Relaxed);
                if off >= 0 {
                    cur.saturating_add(off as u64)
                } else {
                    cur.saturating_sub((-off) as u64)
                }
            }
        }
        .min(self.total_bytes);

        self.position.store(new, Ordering::Relaxed);
        self.ensure(new).map_err(std::io::Error::other)?;
        Ok(new)
    }
}

impl Drop for StreamingDataSource {
    fn drop(&mut self) {
        let _ = self.fetch_tx.send(FetchCommand::Shutdown);
        if let Some(_h) = self.task_handle.take() {}
    }
}
