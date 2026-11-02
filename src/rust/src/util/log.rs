use std::sync::{LazyLock, OnceLock};

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{self, Layer, layer::SubscriberExt, util::SubscriberInitExt};

pub static LOG_ENV: LazyLock<String> =
    LazyLock::new(|| format!("{}_LOGLEVEL", env!("CARGO_CRATE_NAME").to_uppercase()));
pub static LOG_FILE: LazyLock<String> = LazyLock::new(|| format!("{}.log", env!("CARGO_PKG_NAME")));

/// Keeps the file writer's background thread alive for the process lifetime:
/// dropping the guard flushes and stops the appender.
static FILE_LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Resolves the log filter: the app-advertised knob (`YAYMA_LOGLEVEL`) wins,
/// then the generic `RUST_LOG`, then the release default of `warn,yayma=debug`
/// (the app logs everything, dependencies stay quiet at warn; the volume is
/// bounded by the daily rotation and the 7-day prune).
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
/// `yayma.log.<timestamp>`, so the newest sorts last; daily-rotated files
/// from older builds share the prefix and age out the same way.
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

/// Opens this session's log file: `yayma.log.<local timestamp>`, with a
/// numeric suffix when a previous run left a same-second collision.
fn open_session_log(dir: &std::path::Path) -> Option<(std::fs::File, std::path::PathBuf)> {
    let stamp = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S");
    for suffix in ["", "_1", "_2", "_3", "_4"] {
        let path = dir.join(format!("{}.{stamp}{suffix}", *LOG_FILE));
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
            match opened {
                Some((file, log_path)) => {
                    let (writer, guard) =
                        tracing_appender::non_blocking(SizeCappedWriter::new(file));
                    let _ = FILE_LOG_GUARD.set(guard);
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
                        "failed to open session log file, file logging disabled"
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
    use std::io::Write as _;

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
    fn size_capped_writer_passthrough_below_limit() {
        let mut out = Vec::new();
        {
            let mut writer = SizeCappedWriter::new(&mut out);
            writer.write(b"line one\n").unwrap();
            writer.write(b"line two\n").unwrap();
        }
        assert_eq!(out, b"line one\nline two\n");
    }
}
