//! Wave-feedback helpers for `super::system::AudioSystem`.
//!
//! Free functions with explicit parameters; the actor (`system.rs`)
//! keeps its public `send_wave_*` API and routes through one helper
//! taking a post-action so dislike paths keep their queue refresh.

use crate::audio::queue::{QueueManager, as_wave_seed};
use yandex_music::model::track::Track;

/// Post-action after sending wave feedback (refresh kept on dislike paths).
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum WavePostAction {
    None,
    Refresh,
}

/// Explicit-params helper: seed + per-track batch for feedback.
pub fn track_feedback_parts(queue: &QueueManager, track: &Track) -> (String, Option<String>) {
    (as_wave_seed(track), queue.wave_batch_for_track(track))
}
