use std::io::Write as _;
use std::sync::LazyLock;

use tracing_subscriber::{self, Layer, layer::SubscriberExt, util::SubscriberInitExt};

pub static LOG_ENV: LazyLock<String> =
    LazyLock::new(|| format!("{}_LOGLEVEL", env!("CARGO_CRATE_NAME").to_uppercase()));
pub static LOG_FILE: LazyLock<String> = LazyLock::new(|| env!("CARGO_PKG_NAME").to_string());

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Resolves the log filter: the app-advertised knob (`YAYMA_LOGLEVEL`) wins,
/// then the generic `RUST_LOG`, then the release default of `warn,yayma=debug`
/// (the app logs everything, dependencies stay quiet at warn; the volume is
/// bounded by the per-launch rotation and the 3-file prune).
fn make_filter() -> tracing_subscriber::filter::EnvFilter {
    if let Ok(directives) = std::env::var(LOG_ENV.as_str())
        && let Ok(filter) = tracing_subscriber::filter::EnvFilter::try_new(directives)
    {
        return filter;
    }
    tracing_subscriber::filter::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        tracing_subscriber::filter::EnvFilter::new(format!(
            "warn,{}=debug",
            env!("CARGO_CRATE_NAME")
        ))
    })
}

/// Logs panics (message, location, thread) before the default hook so a crash
/// reaches the log files, not just a stdout nobody is watching.
fn install_panic_hook() {
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let location = info
            .location()
            .map(|loc| format!("{}:{}", loc.file(), loc.line()))
            .unwrap_or_else(|| "<unknown>".into());
        let payload = info
            .payload()
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| info.payload().downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<non-string panic payload>".into());
        let thread = std::thread::current();
        let thread_name = thread.name().unwrap_or("<unnamed>");
        tracing::error!(
            location = %location,
            thread = %thread_name,
            "panic: {payload}"
        );
        default_hook(info);
    }));
}

/// Per-session log files kept on disk, current run included.
const MAX_LOG_FILES: usize = 3;
/// Per-file size cap: further entries are dropped until the next launch.
const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;

/// Deletes old session logs so the current run's file (created right after)
/// fits into `MAX_LOG_FILES`. Per-launch files are named
/// `yayma.<month-day_time>.log`, so the newest sorts last; the `yayma.`
/// prefix also ages out the old `yayma.log.<timestamp>` files.
fn prune_old_logs(dir: &std::path::Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let prefix = format!("{}.", LOG_FILE.as_str());
    let mut logs: Vec<std::path::PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(&prefix))
        })
        .collect();
    if logs.len() < MAX_LOG_FILES {
        return;
    }
    logs.sort();
    for path in logs.into_iter().rev().skip(MAX_LOG_FILES - 1) {
        std::fs::remove_file(path).ok();
    }
}

/// Opens this session's log file: `yayma.<month-day_hour.min.sec>.log`, with a
/// numeric suffix when a previous run left a same-second collision.
fn open_session_log(dir: &std::path::Path) -> Option<(std::fs::File, std::path::PathBuf)> {
    let stamp = chrono::Local::now().format("%m-%d_%H.%M.%S");
    for suffix in ["", "_1", "_2", "_3", "_4"] {
        let path = dir.join(format!("{}.{stamp}{suffix}.log", *LOG_FILE));
        match std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
        {
            Ok(file) => return Some((file, path)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// Write adapter capping the session log at `MAX_LOG_BYTES`: the tail beyond
/// the cap is silently dropped (claimed as written, so the non-blocking
/// worker never retries), with a one-line marker at the cut point.
struct SizeCappedWriter<W: std::io::Write> {
    inner: W,
    written: u64,
    truncated: bool,
}

impl<W: std::io::Write> std::io::Write for SizeCappedWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let remaining = MAX_LOG_BYTES.saturating_sub(self.written) as usize;
        let take = buf.len().min(remaining);
        if take > 0 {
            self.inner.write_all(&buf[..take])?;
            self.written += take as u64;
        }
        if take < buf.len() && !self.truncated {
            self.truncated = true;
            let note = b"\n--- log size limit (10 MB) reached, further entries dropped ---\n";
            let _ = self.inner.write_all(note);
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl<W: std::io::Write> SizeCappedWriter<W> {
    fn new(inner: W) -> Self {
        Self {
            inner,
            written: 0,
            truncated: false,
        }
    }
}

/// Log lines queued for the writer thread before new ones are dropped, so a
/// stalled disk cannot grow memory without bound. Far above any real burst
/// (a few MB worst case) yet far below the 128k lines the old appender buffered.
const LOG_QUEUE: usize = 8192;

/// Starts the background thread that owns the session log file and returns the
/// sink for the fmt layer. `None` when the thread cannot be spawned, so the
/// caller falls back to console-only logging instead of panicking.
///
/// There is no guard to keep: a static's destructor never runs at process exit,
/// so the old appender guard flushed nothing today either.
fn spawn_file_writer(file: std::fs::File) -> Option<LogSink> {
    let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(LOG_QUEUE);
    let mut writer = SizeCappedWriter::new(file);
    std::thread::Builder::new()
        .name("log-writer".into())
        .spawn(move || {
            while let Ok(bytes) = rx.recv() {
                // Disk errors only lose the lines already being written; the
                // cap still applies and the process keeps running.
                let _ = writer.write_all(&bytes);
            }
            // Writes go straight to the OS, so the flush is only for tidiness.
            let _ = writer.flush();
        })
        .ok()?;
    Some(LogSink(tx))
}

/// `MakeWriter` adapter handing each formatted event to the writer thread.
struct LogSink(std::sync::mpsc::SyncSender<Vec<u8>>);

/// `Write` view of the sink: every chunk becomes one queued message.
struct LogChunk(std::sync::mpsc::SyncSender<Vec<u8>>);

impl std::io::Write for LogChunk {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        // The chunk is copied because the writer thread owns it. Never blocks:
        // a full queue drops the line, and claiming a full write keeps a gone
        // receiver from surfacing as a broken pipe, which the fmt layer answers
        // with a panic.
        let _ = self.0.try_send(buf.to_vec());
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::writer::MakeWriter<'a> for LogSink {
    type Writer = LogChunk;

    fn make_writer(&'a self) -> LogChunk {
        LogChunk(self.0.clone())
    }
}

pub fn initialize_logging() -> Result<()> {
    install_panic_hook();

    // Add logging to the standard Flutter output stream (via flutter_rust_bridge)
    let console_subscriber = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stdout)
        .with_ansi(true)
        .with_filter(make_filter());

    let registry = tracing_subscriber::registry().with(console_subscriber);

    // A GUI app's stdout is lost unless launched from a terminal, so mirror
    // everything into a per-launch file (max MAX_LOG_FILES on disk,
    // MAX_LOG_BYTES each) in the app data dir. The data dir is set by
    // `initialize_infrastructure` right before this call; without it (e.g.
    // very early failures) only the console layer is installed.
    match crate::app::init::get_data_dir() {
        Some(dir) => {
            let opened = std::fs::create_dir_all(&dir).ok().and_then(|()| {
                prune_old_logs(&dir);
                open_session_log(&dir)
            });
            match opened.and_then(|(file, log_path)| Some((spawn_file_writer(file)?, log_path))) {
                Some((writer, log_path)) => {
                    let file_subscriber = tracing_subscriber::fmt::layer()
                        .with_ansi(false)
                        .with_writer(writer)
                        .with_filter(make_filter());
                    let _ = registry.with(file_subscriber).try_init();
                    tracing::info!(
                        path = %log_path.display(),
                        "file logging initialized (per launch, max 3 files x 10 MB)"
                    );
                }
                None => {
                    let _ = registry.try_init();
                    tracing::warn!(
                        dir = %dir.display(),
                        "failed to start file logging, console only"
                    );
                }
            }
            tracing::info!(
                version = env!("PUBSPEC_VERSION"),
                os = std::env::consts::OS,
                arch = std::env::consts::ARCH,
                "app started"
            );
        }
        None => {
            let _ = registry.try_init();
            tracing::info!(
                version = env!("PUBSPEC_VERSION"),
                os = std::env::consts::OS,
                arch = std::env::consts::ARCH,
                "app started"
            );
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::fmt::writer::MakeWriter as _;

    #[test]
    fn size_capped_writer_stops_at_limit_and_marks_once() {
        let mut out = Vec::new();
        {
            let mut writer = SizeCappedWriter::new(&mut out);
            writer.written = MAX_LOG_BYTES - 4;
            assert_eq!(writer.write(b"hello").unwrap(), 5);
            // Past the cap: dropped without errors, marker written once.
            assert_eq!(writer.write(b"world").unwrap(), 5);
            assert_eq!(writer.write(b"more").unwrap(), 4);
        }
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("hell"));
        assert!(!text.contains("world"));
        assert_eq!(
            text.matches("log size limit (10 MB) reached").count(),
            1,
            "the drop marker must be written exactly once"
        );
    }

    #[test]
    fn log_sink_keeps_chunk_order() {
        let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(LOG_QUEUE);
        let sink = LogSink(tx);
        let mut writer = sink.make_writer();
        writer.write_all(b"line one\n").unwrap();
        writer.write_all(b"line two\n").unwrap();
        assert_eq!(rx.recv().unwrap(), b"line one\n".to_vec());
        assert_eq!(rx.recv().unwrap(), b"line two\n".to_vec());
    }

    #[test]
    fn writer_thread_reaches_the_file() {
        let path = std::env::temp_dir().join(format!("yayma-log-test-{}.log", std::process::id()));
        let file = std::fs::File::create(&path).unwrap();
        let sink = spawn_file_writer(file).unwrap();
        let mut writer = sink.make_writer();
        writer.write_all(b"line one\n").unwrap();
        drop(writer);
        drop(sink);
        // Dropping the sink closes the channel; the thread then flushes and
        // exits, so the content must show up shortly.
        let mut text = String::new();
        for _ in 0..100 {
            text = std::fs::read_to_string(&path).unwrap_or_default();
            if !text.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        std::fs::remove_file(&path).ok();
        assert_eq!(text, "line one\n");
    }

    #[test]
    fn size_capped_writer_passthrough_below_limit() {
        let mut out = Vec::new();
        {
            let mut writer = SizeCappedWriter::new(&mut out);
            writer.write_all(b"line one\n").unwrap();
            writer.write_all(b"line two\n").unwrap();
        }
        assert_eq!(out, b"line one\nline two\n");
    }
}
