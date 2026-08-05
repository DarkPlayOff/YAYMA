use parking_lot::Mutex;
use std::sync::Arc;

/// Publishes a stream's buffering state to the UI.
pub type BufferingReport = Box<dyn Fn(bool) + Send + Sync>;

/// Routes a stream's buffering state to the UI, but only for the session that is
/// actually being played.
///
/// `StreamManager::prewarm` builds sessions ahead of time, so a session can buffer
/// long before — or without ever — becoming the current track, and reporting from
/// it would raise the spinner over an unrelated, happily playing track. A gate
/// therefore starts disarmed and is armed by `AudioController` at the moment the
/// session is handed to the engine.
///
/// Prewarmed sessions used to be built with no signal at all, which left them mute
/// even *after* adoption: every auto-advanced track lost both the spinner and the
/// controller's 15s buffering watchdog, so a stalled connection played as silence
/// while the UI showed normal playback.
#[derive(Default)]
pub struct BufferingGate {
    report: Mutex<Option<BufferingReport>>,
}

impl BufferingGate {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Starts publishing this stream's buffering state through `report`.
    pub fn arm(&self, report: BufferingReport) {
        *self.report.lock() = Some(report);
    }

    pub fn set(&self, buffering: bool) {
        if let Some(report) = self.report.lock().as_ref() {
            report(buffering);
        }
    }
}
