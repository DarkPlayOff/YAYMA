use crate::audio::progress::TrackProgress;
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
use super::buffering::BufferingGate;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Why a stream source could not be opened.
///
/// The distinction matters upstream: a URL the server rejected is dead and must
/// leave the cache, while a transport failure must keep it for the next attempt.
#[derive(Debug, thiserror::Error)]
pub enum StreamSourceError {
    /// The server answered but refused to serve the stream.
    #[error("stream url rejected (status {0})")]
    Rejected(u16),
    /// Transport, parsing or timeout failure: retrying the same URL may work.
    #[error(transparent)]
    Other(#[from] Box<dyn std::error::Error + Send + Sync>),
}

type FetchFuture = std::pin::Pin<
    Box<
        dyn std::future::Future<
                Output = std::result::Result<Result<bytes::Bytes>, tokio::time::error::Elapsed>,
            > + Send
            + 'static,
    >,
>;

const INITIAL_BUFFER_SECONDS: u64 = 5;
const MIN_INITIAL_DATA: usize = 512 * 1024;
const MAX_ATTEMPTS: usize = 20; // 10 seconds total while waiting for a range
const RANGE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_RANGE_RETRIES: usize = 3;
/// Body-read floor: a range request is allowed at least this transfer rate.
/// Slower-but-flowing links would turn every large prefetch into a timeout
/// under a fixed cap, starving playback exactly when it needs the buffer.
const RANGE_BODY_BYTES_PER_MS: u64 = 64; // 64 KB/s

/// Deadline for reading one range body: the fixed connect/headers budget
/// plus a size-proportional transfer budget. A dead peer is still caught by
/// the client-level `read_timeout`; this only has to outlive a slow link.
fn range_body_timeout(bytes: u64) -> Duration {
    RANGE_TIMEOUT + Duration::from_millis(bytes / RANGE_BODY_BYTES_PER_MS)
}

enum FetchCommand {
    Fetch {
        start: u64,
        end: u64,
        generation: u64,
    },
    Shutdown,
}

/// Charges one retry when a fetch notification brought no new bytes; growth
/// resets the budget so a slow but live fetch never times out. Returns `true`
/// when the attempt budget is spent.
fn account_wait(available: usize, last_available: &mut usize, attempts: &mut usize) -> bool {
    if available > *last_available {
        *attempts = 0;
    } else {
        *attempts += 1;
    }
    *last_available = available;
    *attempts >= MAX_ATTEMPTS
}

pub struct StreamingDataSource {
    total_bytes: u64,
    buffer: Arc<Mutex<BufferState>>,
    position: Arc<AtomicU64>,
    generation: Arc<AtomicU64>,
    fetch_tx: Sender<FetchCommand>,
    fetch_rx: Receiver<()>,
    task_handle: Option<tokio::task::JoinHandle<()>>,
    buffering: Arc<BufferingGate>,
    prefetch_size: usize,
}

impl StreamingDataSource {
    pub async fn new(
        client: Client,
        url: String,
        mirror_urls: Vec<String>,
        progress: Arc<TrackProgress>,
        buffering: Arc<BufferingGate>,
        duration_ms: Option<u64>,
    ) -> std::result::Result<Self, StreamSourceError> {
        let progress_generation = progress.get_generation();

        // 1. Fetch first chunk to get total content size
        let mut urls = Vec::with_capacity(1 + mirror_urls.len());
        urls.push(url.clone());
        urls.extend(mirror_urls);

        let initial_size = MIN_INITIAL_DATA;
        let resp = Self::fetch_range_response(&client, &urls, 0, initial_size as u64)
            .await?
            .error_for_status()
            .map_err(|e| match e.status() {
                Some(status) => StreamSourceError::Rejected(status.as_u16()),
                None => StreamSourceError::Other(e.into()),
            })?;

        let total = if let Some(range) = resp.headers().get("content-range") {
            let s = range
                .to_str()
                .map_err(|_| StreamSourceError::Other("invalid content-range header".into()))?;
            if let Some(slash) = s.find('/') {
                s[slash + 1..].parse::<u64>().map_err(|_| {
                    StreamSourceError::Other("invalid total size in content-range".into())
                })?
            } else {
                return Err(StreamSourceError::Other(
                    "invalid content-range format".into(),
                ));
            }
        } else {
            resp.content_length()
                .ok_or_else(|| StreamSourceError::Other("content-length missing".into()))?
        };

        progress.set_total_bytes(total);

        // 2. Calculate dynamic buffer sizes based on bit rate
        // We target:
        // - BUFFER_SIZE = 30 seconds of audio
        // - PREFETCH_TRIGGER = 15 seconds of audio
        // - PREFETCH_SIZE = 10 seconds of audio
        let (buffer_size, prefetch_trigger, prefetch_size) = if let Some(dur_ms) = duration_ms
            && dur_ms > 0
        {
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
            (8 * 1024 * 1024, 256 * 1024, 1024 * 1024)
        };

        let initial_data = tokio::time::timeout(
            range_body_timeout(initial_size as u64),
            resp.bytes(),
        )
        .await
        .map_err(|_| StreamSourceError::Other("initial stream range body timed out".into()))?
        .map_err(|e| StreamSourceError::Other(e.into()))?;
        let initial_data_len = initial_data.len();

        let buffer = Arc::new(Mutex::new(BufferState::new(
            total,
            buffer_size,
            prefetch_trigger,
        )));
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
            urls,
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
            buffering,
            prefetch_size,
        };

        let initial_required = duration_ms
            .filter(|duration| *duration > 0)
            .map(|duration| {
                ((total as f64 * INITIAL_BUFFER_SECONDS as f64 * 1000.0 / duration as f64) as usize)
                    .max(MIN_INITIAL_DATA)
                    .min(total as usize)
            })
            .unwrap_or(MIN_INITIAL_DATA);
        if initial_required > initial_data_len {
            // The probe above already populated [0, initial_data_len). Continue
            // from its contiguous end instead of requesting the same bytes again.
            src.fetch(
                initial_data_len as u64,
                (initial_required - initial_data_len) as u64,
            )?;
        }
        src.wait_for_async(0, initial_required).await?;
        Ok(src)
    }

    async fn fetch_loop_async(ctx: FetchContext) {
        let mut current_fetch = None;

        loop {
            let has_fetch = current_fetch.is_some();

            tokio::select! {
                res = async {
                    if let Some((ref mut fut, _, _, _)) = current_fetch {
                        fut.await
                    } else {
                        std::future::pending().await
                    }
                }, if has_fetch => {
                    let Some((_, start, _end, request_generation)) = current_fetch.take() else {
                        // `has_fetch` was true when the branch was selected.
                        continue;
                    };
                    match res {
                        Ok(Ok(data)) => {
                            let current_gen = ctx.generation.load(Ordering::Acquire);
                            if request_generation == current_gen {
                                let maybe_buffered = {
                                    let mut buf = ctx.buffer.lock();
                                    if buf.append(data, start) {
                                        Some(buf.max_buffered_from_start())
                                    } else {
                                        None
                                    }
                                };

                                if request_generation == current_gen
                                    && ctx.progress_generation == ctx.progress.get_generation()
                                    && let Some(buffered_pos) = maybe_buffered
                                  {
                                    ctx.progress.set_buffered_bytes(buffered_pos);
                                }
                            }
                            let _ = ctx.tx_res.send(());
                        }
                        Ok(Err(err)) => {
                            tracing::error!(error = ?err, "stream_fetch_failed");
                            {
                                let mut buf = ctx.buffer.lock();
                                buf.clear_pending();
                            }
                            let _ = ctx.tx_res.send(());
                        }
                        Err(_) => {
                            {
                                let mut buf = ctx.buffer.lock();
                                buf.clear_pending();
                            }
                            let _ = ctx.tx_res.send(());
                        }
                    }
                }
                cmd_res = ctx.rx_cmd.recv_async() => {
                    match cmd_res {
                        Ok(FetchCommand::Shutdown) => break,
                        Ok(FetchCommand::Fetch { start: new_start, end: new_end, generation: new_gen }) => {
                            let current_gen = ctx.generation.load(Ordering::Acquire);
                            if new_gen == current_gen {
                                if let Some((_, _, _, old_gen)) = current_fetch {
                                    if new_gen > old_gen {
                                        {
                                            let mut buf = ctx.buffer.lock();
                                            buf.clear_pending();
                                            buf.mark_pending(new_start, new_end);
                                        }
                                        let client = ctx.client.clone();
                                        let urls = ctx.urls.clone();
                                        let fut = Self::fetch_range_timeout(client, urls, new_start, new_end);
                                        current_fetch = Some((fut, new_start, new_end, new_gen));
                                    } else {
                                        let _ = ctx.tx_res.send(());
                                    }
                                } else {
                                    {
                                        let mut buf = ctx.buffer.lock();
                                        buf.mark_pending(new_start, new_end);
                                    }
                                    let client = ctx.client.clone();
                                    let urls = ctx.urls.clone();
                                    let fut = Self::fetch_range_timeout(client, urls, new_start, new_end);
                                    current_fetch = Some((fut, new_start, new_end, new_gen));
                                }
                            } else {
                                let _ = ctx.tx_res.send(());
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
        }
    }

    fn fetch_range_timeout(client: Client, urls: Vec<String>, start: u64, end: u64) -> FetchFuture {
        // The outer cap covers all retry attempts of one fetch; scaled with
        // the body size so it never fires before a single slow attempt could
        // have finished on its own.
        let budget = range_body_timeout(end.saturating_sub(start)).saturating_mul(MAX_RANGE_RETRIES as u32);
        Box::pin(tokio::time::timeout(
            budget,
            async move { Self::fetch_range_async(&client, &urls, start, end).await },
        ))
    }

    async fn fetch_range_response(
        client: &Client,
        urls: &[String],
        start: u64,
        size: u64,
    ) -> std::result::Result<reqwest::Response, StreamSourceError> {
        let end = start.saturating_add(size);
        let mut last = None;
        for attempt in 0..MAX_RANGE_RETRIES {
            let url = &urls[attempt % urls.len()];
            match tokio::time::timeout(
                RANGE_TIMEOUT,
                client
                    .get(url)
                    .header(
                        "Range",
                        format!("bytes={}-{}", start, end.saturating_sub(1)),
                    )
                    .send(),
            )
            .await
            {
                Ok(Ok(resp)) if resp.status().is_success() || resp.status().is_redirection() => {
                    return Ok(resp);
                }
                Ok(Ok(resp)) => last = Some(StreamSourceError::Rejected(resp.status().as_u16())),
                Ok(Err(err)) => last = Some(StreamSourceError::Other(err.into())),
                Err(_) => {
                    last = Some(StreamSourceError::Other(
                        "stream range request timed out".into(),
                    ));
                }
            }
            if attempt + 1 < MAX_RANGE_RETRIES {
                tokio::time::sleep(Duration::from_millis(200 * (attempt as u64 + 1))).await;
            }
        }
        Err(last.unwrap_or_else(|| StreamSourceError::Other("stream range request failed".into())))
    }

    async fn fetch_range_async(
        client: &Client,
        urls: &[String],
        start: u64,
        end: u64,
    ) -> Result<bytes::Bytes> {
        let hdr = format!("bytes={}-{}", start, end.saturating_sub(1));
        let mut last_error: Option<Box<dyn std::error::Error + Send + Sync>> = None;
        for attempt in 0..MAX_RANGE_RETRIES {
            let url = &urls[attempt % urls.len()];
            match tokio::time::timeout(RANGE_TIMEOUT, client.get(url).header("Range", &hdr).send())
                .await
            {
                Ok(Ok(resp)) => {
                    let status = resp.status();
                    // Fail fast on client errors (e.g. 403 expired URL, 404):
                    // retrying other mirrors won't help and only adds latency.
                    // 408/429 are retryable.
                    if status.is_client_error() && status.as_u16() != 408 && status.as_u16() != 429
                    {
                        return Err(Box::from(format!(
                            "stream url rejected (status {})",
                            status.as_u16()
                        )));
                    }
                    if status.is_client_error() {
                        last_error = Some(Box::from(format!(
                            "stream url rejected (status {})",
                            status.as_u16()
                        )));
                    } else {
                        match resp.error_for_status() {
                            Ok(resp) => {
                                // Validate Content-Range when server answers 206.
                                if resp.status().as_u16() == 206
                                    && let Some(range) = resp.headers().get("content-range")
                                    && let Ok(s) = range.to_str()
                                    && let Some(unit) = s.split_whitespace().next()
                                    && unit != "bytes"
                                {
                                    last_error = Some("invalid content-range unit".into());
                                } else {
                                    match tokio::time::timeout(
                                        range_body_timeout(end.saturating_sub(start)),
                                        resp.bytes(),
                                    )
                                    .await
                                    {
                                        Ok(Ok(bytes)) => {
                                            if bytes.is_empty() {
                                                last_error = Some("empty stream range body".into());
                                            } else {
                                                return Ok(bytes);
                                            }
                                        }
                                        Ok(Err(e)) => last_error = Some(e.into()),
                                        Err(_) => {
                                            last_error = Some("stream range body timed out".into())
                                        }
                                    }
                                }
                            }
                            Err(e) => last_error = Some(e.into()),
                        }
                    }
                }
                Ok(Err(e)) => {
                    last_error = Some(e.into());
                }
                Err(e) => {
                    last_error = Some(e.into());
                }
            }
            if attempt + 1 < MAX_RANGE_RETRIES {
                tokio::time::sleep(Duration::from_millis(200 * (attempt as u64 + 1))).await;
            }
        }
        Err(last_error.unwrap_or_else(|| "stream range request exhausted retries".into()))
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

    /// Bytes that must be buffered at `pos` for `min` to be satisfiable, and
    /// the amount already there. A slice near the tail simply has fewer than
    /// `min` bytes left, so waiting for `min` there would never be satisfied.
    fn wait_target(&self, pos: u64, min: usize) -> (usize, usize) {
        let needed = min.min(self.total_bytes.saturating_sub(pos) as usize);
        let available = self.buffer.lock().available_from(pos);
        (needed, available)
    }

    /// Blocks (on the decode thread) until `min` bytes are buffered at `pos`.
    ///
    /// The async counterpart below serves `new`. The loops stay separate because
    /// one waits on a crossbeam channel and the other on tokio, but the byte
    /// budget and the retry accounting are shared: a notification that did not
    /// grow the buffer burns an attempt, so a transient failure cannot silently
    /// double the wait.
    fn wait_for(&self, pos: u64, min: usize) -> Result<()> {
        let (needed, mut last_available) = self.wait_target(pos, min);
        if last_available >= needed {
            return Ok(());
        }

        self.buffering.set(true);

        let mut attempts = 0usize;
        let mut result = Ok(());

        while attempts < MAX_ATTEMPTS {
            match self.fetch_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(_) => {
                    let available = self.buffer.lock().available_from(pos);
                    if available >= needed {
                        break;
                    }
                    if account_wait(available, &mut last_available, &mut attempts) {
                        break;
                    }
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

        self.buffering.set(false);
        result
    }

    async fn wait_for_async(&self, pos: u64, min: usize) -> Result<()> {
        let (needed, mut last_available) = self.wait_target(pos, min);
        if last_available >= needed {
            return Ok(());
        }

        self.buffering.set(true);

        let mut attempts = 0usize;
        let mut result = Ok(());

        while attempts < MAX_ATTEMPTS {
            match tokio::time::timeout(Duration::from_millis(500), self.fetch_rx.recv_async()).await
            {
                Ok(Ok(_)) => {
                    let available = self.buffer.lock().available_from(pos);
                    if available >= needed {
                        break;
                    }
                    if account_wait(available, &mut last_available, &mut attempts) {
                        break;
                    }
                }
                Ok(Err(_)) => {
                    result = Err("fetch channel closed".into());
                    break;
                }
                Err(_) => {
                    attempts += 1;
                }
            }
        }

        if attempts >= MAX_ATTEMPTS {
            result = Err("wait_for_data timed out".into());
        }

        self.buffering.set(false);
        result
    }

    fn ensure(&self, pos: u64) -> Result<()> {
        let (is_pending, pending_end) = {
            let buf = self.buffer.lock();
            if buf.contains(pos) {
                return Ok(());
            }
            if let Some((s, e)) = buf.pending
                && pos >= s
                && pos < e
            {
                (true, e)
            } else {
                (false, 0)
            }
        };

        if is_pending {
            let needed_bytes = (pending_end - pos) as usize;
            self.wait_for(pos, MIN_INITIAL_DATA.min(needed_bytes))?;

            // Only `contains` proves the byte at `pos` is readable: after a backwards
            // seek into a hole, `eof` is still set from the already-fetched tail while
            // `pos` itself holds nothing.
            let has_data = {
                let buf = self.buffer.lock();
                buf.contains(pos)
            };
            if has_data {
                return Ok(());
            }
        }

        let _ = self.generation.fetch_add(1, Ordering::Release);
        {
            let mut buf = self.buffer.lock();
            buf.clear(pos);
        }

        let size = self
            .prefetch_size
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
                let start = buf.end_pos(pos);
                let size = self
                    .prefetch_size
                    .min((self.total_bytes.saturating_sub(start)) as usize);
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
    urls: Vec<String>,
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
        } else if !buf.is_empty() {
            // `ensure` reported success, so `pos` had to be readable. Returning Ok(0)
            // from the middle of the file would be read as a clean end of stream and
            // would silently truncate the track instead of surfacing the fault.
            return Err(std::io::Error::other(format!(
                "no buffered data at position {} of {}",
                pos, self.total_bytes
            )));
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
        if let Some(handle) = self.task_handle.take() {
            handle.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_body_timeout_scales_with_size_and_keeps_a_floor() {
        // Headers/connect keep the fixed budget even for an empty body.
        assert_eq!(range_body_timeout(0), RANGE_TIMEOUT);
        // ~64 KB/s floor: 512 KB buys ~8 extra seconds, 4 MB over a minute,
        // so a slow-but-flowing link can deliver a large prefetch.
        assert_eq!(
            range_body_timeout(512 * 1024),
            RANGE_TIMEOUT + Duration::from_millis(8192)
        );
        assert!(range_body_timeout(4 * 1024 * 1024) > RANGE_TIMEOUT * 3);
    }

    #[test]
    fn wait_budget_resets_while_bytes_arrive() {
        let (mut last, mut attempts) = (0usize, MAX_ATTEMPTS - 1);

        assert!(
            !account_wait(64, &mut last, &mut attempts),
            "growth must reset the budget"
        );
        assert_eq!(attempts, 0);
        assert_eq!(last, 64);
    }

    #[test]
    fn wait_budget_runs_out_without_progress() {
        let (mut last, mut attempts) = (64usize, 0);

        for _ in 0..MAX_ATTEMPTS - 1 {
            assert!(!account_wait(64, &mut last, &mut attempts));
        }
        assert!(
            account_wait(64, &mut last, &mut attempts),
            "stalled fetches must time out"
        );
    }
}
