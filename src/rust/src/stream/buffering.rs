use parking_lot::Mutex;
use std::sync::Arc;

/// Publishes a stream's buffering state to the UI.
pub type BufferingReport = Arc<dyn Fn(bool) + Send + Sync>;

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
        // Clone the handle and drop the lock before calling out: the report
        // touches signals and wakes tasks, which must never run under our lock.
        let report = self.report.lock().clone();
        if let Some(report) = report {
            report(buffering);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use parking_lot::Mutex;

    #[test]
    fn set_before_arm_is_a_no_op() {
        let gate = BufferingGate::new();
        gate.set(true);
        gate.set(false);
    }

    #[test]
    fn armed_gate_forwards_every_change() {
        let gate = BufferingGate::new();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        gate.arm(Arc::new(move |b| sink.lock().push(b)));

        gate.set(true);
        gate.set(false);

        assert_eq!(*seen.lock(), vec![true, false]);
    }

    #[test]
    fn report_may_call_back_into_the_gate() {
        // Regression: the report used to run while the gate's mutex was held,
        // so any handler that touched the gate again deadlocked.
        let gate = BufferingGate::new();
        let inner = gate.clone();
        gate.arm(Arc::new(move |b| {
            if b {
                inner.set(false);
            }
        }));

        gate.set(true);
    }
}
