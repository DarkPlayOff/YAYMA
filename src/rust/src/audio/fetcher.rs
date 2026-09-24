use crate::http::{ApiService, SessionExt};
use crate::util::reactive::Signal;
use chrono::Utc;
use im::Vector;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinHandle;
use tracing::error;
use yandex_music::model::rotor::feedback::{StationFeedback, StationFeedbackEvent};
use yandex_music::model::rotor::session::Session;
use yandex_music::model::track::Track;

pub const FETCH_BATCH_SIZE: usize = 50;
pub const WAVE_VISIBLE_TRACKS: usize = 3;

/// A wave session is usable for feedback (`rotor/session/{id}/feedback`) and
/// for paging (`rotor/session/{id}/tracks`) only while the server keeps
/// returning a non-empty `radio_session_id`. Some `/tracks` responses come
/// back with it missing/null — adopting such a response verbatim poisons the
/// stored session: every later `trackStarted` goes to the
/// `user:onyourwave` fallback URL with a foreign `batch_id` (HTTP 400), and
/// every later page request fails with `MissingWaveSession`.
pub fn is_usable_wave_session(session: &Session) -> bool {
    session
        .radio_session_id
        .as_deref()
        .is_some_and(|id| !id.is_empty())
}

/// Single map-insertion point for per-track `batchId` attribution.
/// All wave serving paths (`remember_wave_batch`, session creation,
/// background extension) funnel here so the key/value shape can't drift.
fn insert_batch_ids_into(
    map: &Mutex<HashMap<String, String>>,
    batch_id: &str,
    ids: impl IntoIterator<Item = String>,
) {
    let mut guard = map.lock();
    for id in ids {
        guard.insert(id, batch_id.to_string());
    }
}

/// Shared repair for stored wave sessions: keep the stable
/// `radio_session_id` and the last known `wave` descriptor when a
/// response comes back without them. Logging stays at the call sites
/// (different contexts log different fields); only the assignment is shared.
fn preserve_session_identity(session: &mut Session, prev: Option<&Session>) {
    if session
        .radio_session_id
        .as_deref()
        .is_none_or(|id| id.is_empty())
    {
        session.radio_session_id = prev.and_then(|s| s.radio_session_id.clone());
    }
    if session.wave.is_none()
        && let Some(prev_wave) = prev.and_then(|s| s.wave.clone())
    {
        session.wave = Some(prev_wave);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    AlreadyFetching,
    MissingWaveSession,
    PendingIdsNotEmpty,
}

pub enum FetchTaskResult {
    Playlist {
        ids: Vec<String>,
        result: Result<Vec<Track>, String>,
    },
    Wave {
        result: Result<(Vec<Track>, Session), String>,
        /// Finish/skip events piggybacked on the failed page request.
        /// The caller must prepend them to its pending queue (mirrors the
        /// original client's `storeFeedbacksForSending` on failure) so they
        /// are retried with the next page instead of being lost.
        failed_feedbacks: Vec<WaveTrackEvent>,
    },
}

#[derive(Debug, Clone)]
pub enum WaveTrackOutcome {
    Finished,
    Skipped,
}

#[derive(Debug, Clone)]
pub struct WaveTrackEvent {
    pub track_id: String,
    /// `batchId` of the page response that delivered this track.
    /// The original client stores a per-track batch id with every vibe
    /// entity and sends it back with that track's feedback; using the
    /// current session's batch for all tracks breaks feedback attribution
    /// once more than one page has been served.
    pub batch_id: Option<String>,
    pub total_played: Duration,
    pub track_length: Option<Duration>,
    pub outcome: WaveTrackOutcome,
}

pub struct FetchState {
    pub task: Option<JoinHandle<FetchTaskResult>>,
    pub pending_track_ids: Vec<String>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
    /// `track.id -> batchId` for every served wave track. The stored wave
    /// session is intentionally stable (see `set_wave_session`): page
    /// responses only extend this map via `remember_wave_batch`.
    wave_batch_ids: Arc<Mutex<HashMap<String, String>>>,
    playlist_failure_requeues: u8,
}

impl Default for FetchState {
    fn default() -> Self {
        Self::new()
    }
}

impl FetchState {
    pub fn new() -> Self {
        Self {
            task: None,
            pending_track_ids: Vec::new(),
            wave_session: Arc::new(Mutex::new(None)),
            wave_batch_ids: Arc::new(Mutex::new(HashMap::new())),
            playlist_failure_requeues: 0,
        }
    }

    pub fn reset(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        self.pending_track_ids.clear();
        self.playlist_failure_requeues = 0;
        *self.wave_session.lock() = None;
        self.wave_batch_ids.lock().clear();
    }

    pub fn set_pending_ids(&mut self, ids: Vec<String>) -> Result<(), FetchError> {
        if !self.pending_track_ids.is_empty() {
            return Err(FetchError::PendingIdsNotEmpty);
        }
        self.pending_track_ids = ids;
        Ok(())
    }

    pub fn is_fetching(&self) -> bool {
        self.task.is_some()
    }

    pub fn is_finished(&self) -> bool {
        self.task.as_ref().map(|t| t.is_finished()).unwrap_or(false)
    }

    /// Store the session created by `rotor/session/new` (or an explicit
    /// recreate). This is the ONLY path that may replace the stored session:
    /// the original client keeps the created session stable for the whole
    /// wave context and only appends page responses as track lists.
    /// Page (`rotor/session/{id}/tracks`) responses must go through
    /// `remember_wave_batch` instead — adopting them verbatim is what made
    /// the wave randomly reset (rotating `batch_id`, occasionally missing or
    /// `terminated` session state).
    pub fn set_wave_session(&self, mut session: Session) {
        let mut guard = self.wave_session.lock();
        // The radio session id is stable for the lifetime of a session while
        // batch_id rotates on every /tracks call. Never let a response that
        // is missing it wipe the last good one (see is_usable_wave_session).
        if session
            .radio_session_id
            .as_deref()
            .is_none_or(|id| id.is_empty())
        {
            error!(
                batch_id = %session.batch_id,
                terminated = session.terminated,
                sequence_len = session.sequence.len(),
                "wave_session_missing_radio_id_keep_previous"
            );
        }
        if session.terminated {
            error!(
                batch_id = %session.batch_id,
                sequence_len = session.sequence.len(),
                "wave_session_terminated"
            );
        }
        preserve_session_identity(&mut session, guard.as_ref());
        self.remember_wave_batch_locked(&session.batch_id, &session.sequence);
        *guard = Some(session);
    }

    /// Record which `batchId` delivered each track of a `/tracks` page
    /// response. Deliberately does NOT touch the stored session.
    pub fn remember_wave_batch(&self, batch_id: &str, tracks: &[Track]) {
        insert_batch_ids_into(
            &self.wave_batch_ids,
            batch_id,
            tracks.iter().map(|t| t.id.clone()),
        );
    }

    fn remember_wave_batch_locked(
        &self,
        batch_id: &str,
        sequence: &[yandex_music::model::rotor::session::SequenceItem],
    ) {
        insert_batch_ids_into(
            &self.wave_batch_ids,
            batch_id,
            sequence.iter().map(|item| item.track.id.clone()),
        );
    }

    /// Per-track `batchId` for feedback attribution (`track.id` key).
    /// Falls back to the stored session's batch when the track was served
    /// before this map existed.
    pub fn wave_batch_for(&self, track_id: &str) -> Option<String> {
        if let Some(batch) = self.wave_batch_ids.lock().get(track_id).cloned() {
            return Some(batch);
        }
        self.wave_session
            .lock()
            .as_ref()
            .map(|s| s.batch_id.clone())
    }

    pub fn wave_batch_ids_arc(&self) -> Arc<Mutex<HashMap<String, String>>> {
        self.wave_batch_ids.clone()
    }

    pub fn wave_session_clone(&self) -> Option<Session> {
        self.wave_session.lock().clone()
    }

    pub fn wave_session_arc(&self) -> Arc<Mutex<Option<Session>>> {
        self.wave_session.clone()
    }

    pub fn trigger_playlist_batch(&mut self, api: Arc<ApiService>) -> Result<(), FetchError> {
        if self.is_fetching() {
            return Err(FetchError::AlreadyFetching);
        }
        let count = FETCH_BATCH_SIZE.min(self.pending_track_ids.len());
        let ids: Vec<String> = self.pending_track_ids.drain(0..count).collect();

        self.task = Some(tokio::spawn(async move {
            let mut last_error = None;
            for attempt in 0..3 {
                let result =
                    tokio::time::timeout(Duration::from_secs(10), api.fetch_tracks(ids.clone()))
                        .await;
                match result {
                    Ok(Ok(tracks)) => {
                        let valid: Vec<Track> = tracks
                            .into_iter()
                            .filter(|t| t.available.unwrap_or(false))
                            .collect();
                        return FetchTaskResult::Playlist {
                            ids,
                            result: Ok(valid),
                        };
                    }
                    Ok(Err(e)) => last_error = Some(e.to_string()),
                    Err(_) => last_error = Some("request timed out".to_string()),
                }
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_millis(250 * (1 << attempt))).await;
                }
            }
            error!(error = ?last_error, "track_fetch_failed");
            FetchTaskResult::Playlist {
                ids,
                result: Err(last_error.unwrap_or_else(|| "track fetch failed".into())),
            }
        }));
        Ok(())
    }

    pub fn trigger_wave_batch(
        &mut self,
        api: Arc<ApiService>,
        wave_seeds: Vec<String>,
        pending_feedback: Vec<WaveTrackEvent>,
    ) -> Result<(), FetchError> {
        if self.is_fetching() {
            return Err(FetchError::AlreadyFetching);
        }
        let session = match self.wave_session_clone() {
            Some(s) => s,
            None => return Err(FetchError::MissingWaveSession),
        };
        let session_id = match session.radio_session_id.clone() {
            Some(id) if !id.is_empty() => id,
            _ => return Err(FetchError::MissingWaveSession),
        };

        self.task = Some(tokio::spawn(async move {
            let default_batch = session.batch_id.clone();
            // Kept aside so a failed page request can hand its finish/skip
            // events back for retry instead of dropping them.
            let retry_events = pending_feedback.clone();
            let feedbacks: Vec<StationFeedback> = pending_feedback
                .into_iter()
                .map(|e| {
                    let batch_id = e.batch_id.clone().or(Some(default_batch.clone()));
                    StationFeedback {
                        batch_id,
                        event: StationFeedbackEvent {
                            track_id: Some(e.track_id),
                            item_type: Some(
                                match e.outcome {
                                    WaveTrackOutcome::Finished => "trackFinished",
                                    WaveTrackOutcome::Skipped => "skip",
                                }
                                .to_string(),
                            ),
                            timestamp: Utc::now(),
                            from: None,
                            total_played: Some(e.total_played),
                            track_length: e.track_length,
                        },
                        from: Some(session.source_id().to_string()),
                    }
                })
                .collect();

            match api
                .get_session_tracks(session_id, wave_seeds, feedbacks)
                .await
            {
                Ok(response) => {
                    let new_tracks: Vec<Track> = response
                        .sequence
                        .iter()
                        .map(|item| item.track.clone())
                        .collect();
                    FetchTaskResult::Wave {
                        result: Ok((new_tracks, response)),
                        failed_feedbacks: Vec::new(),
                    }
                }
                Err(e) => {
                    error!(error = %e, "wave_fetch_failed");
                    FetchTaskResult::Wave {
                        result: Err(e.to_string()),
                        failed_feedbacks: retry_events,
                    }
                }
            }
        }));
        Ok(())
    }

    /// Returns `(tracks, wave page response, failed wave feedbacks)`.
    /// Page responses are returned verbatim for their track list — the
    /// caller must feed them to `remember_wave_batch`, never to
    /// `set_wave_session`.
    pub async fn await_task(
        &mut self,
    ) -> Option<(
        Vec<Track>,
        Option<Session>,
        Vec<WaveTrackEvent>,
    )> {
        self.await_task_timeout(Duration::from_secs(30)).await
    }

    /// Bounded wait for the in-flight fetch so the audio actor never blocks
    /// on a ~30s network fetch. On timeout the task handle is kept and the
    /// result is picked up later via poll_fetch().
    pub async fn await_task_timeout(
        &mut self,
        timeout: Duration,
    ) -> Option<(
        Vec<Track>,
        Option<Session>,
        Vec<WaveTrackEvent>,
    )> {
        if self.task.is_none() {
            return None;
        }
        if !self.is_finished() {
            // Wait without consuming the handle: `&mut JoinHandle` is itself
            // a Future, so a timeout leaves `self.task` intact for poll_fetch().
            if let Some(task) = self.task.as_mut() {
                let _ = tokio::time::timeout(timeout, &mut *task).await;
            }
            if !self.is_finished() {
                return None;
            }
        }
        self.await_task_inner().await
    }

    async fn await_task_inner(
        &mut self,
    ) -> Option<(
        Vec<Track>,
        Option<Session>,
        Vec<WaveTrackEvent>,
    )> {
        let task = self.task.take()?;
        let result = match task.await {
            Ok(result) => result,
            Err(_) => {
                self.playlist_failure_requeues = 0;
                return None;
            }
        };

        match result {
            FetchTaskResult::Playlist { ids, result } => match result {
                Ok(tracks) => {
                    self.playlist_failure_requeues = 0;
                    Some((tracks, None, Vec::new()))
                }
                Err(error) => {
                    error!(error = %error, "track_fetch_failed");
                    if self.playlist_failure_requeues == 0 {
                        self.pending_track_ids.splice(0..0, ids);
                        self.playlist_failure_requeues = 1;
                    }
                    Some((vec![], None, Vec::new()))
                }
            },
            FetchTaskResult::Wave {
                result,
                failed_feedbacks,
            } => {
                self.playlist_failure_requeues = 0;
                Some(result.map_or(
                    (vec![], None, failed_feedbacks),
                    |(tracks, session)| (tracks, Some(session), Vec::new()),
                ))
            }
        }
    }
}

pub struct WaveExtensionHandles {
    pub queue: Signal<Vector<Track>>,
    pub queue_length: Signal<usize>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
    pub wave_batch_ids: Arc<Mutex<HashMap<String, String>>>,
    pub playback_context: Arc<Mutex<crate::audio::queue::PlaybackContext>>,
    pub generation: u64,
    pub generation_ref: Arc<std::sync::atomic::AtomicU64>,
}

impl WaveExtensionHandles {
    /// Apply only if no load()/clear() happened since the task was spawned.
    pub fn apply(self, additional: Vector<Track>, mut session: Session) {
        if self
            .generation_ref
            .load(std::sync::atomic::Ordering::Relaxed)
            != self.generation
        {
            return;
        }
        {
            let guard = self.wave_session.lock();
            // Same poisoning guard as set_wave_session: a create_session
            // response without radio_session_id must not wipe a good one.
            if session
                .radio_session_id
                .as_deref()
                .is_none_or(|id| id.is_empty())
            {
                error!(
                    batch_id = %session.batch_id,
                    terminated = session.terminated,
                    "wave_session_missing_radio_id_keep_previous"
                );
            }
            preserve_session_identity(&mut session, guard.as_ref());
        }
        *self.wave_session.lock() = Some(session.clone());
        insert_batch_ids_into(
            &self.wave_batch_ids,
            &session.batch_id,
            additional.iter().map(|track| track.id.clone()),
        );
        *self.playback_context.lock() = crate::audio::queue::PlaybackContext::Wave(session);

        let visible: Vector<Track> = additional
            .iter()
            .take(WAVE_VISIBLE_TRACKS)
            .cloned()
            .collect();

        self.queue.update(|q| q.extend(visible));
        self.queue_length
            .set(self.queue.with(|q: &Vector<Track>| q.len()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_pending_ids_rejects_replacement() {
        let mut state = FetchState::new();
        state.set_pending_ids(vec!["first".into()]).unwrap();

        assert_eq!(
            state.set_pending_ids(vec!["replacement".into()]),
            Err(FetchError::PendingIdsNotEmpty)
        );
        assert_eq!(state.pending_track_ids, vec!["first"]);
    }

    #[test]
    fn reset_clears_pending_and_session() {
        let mut state = FetchState::new();
        state.set_pending_ids(vec!["a".into()]).unwrap();
        state.reset();
        assert!(state.pending_track_ids.is_empty());
        assert!(!state.is_fetching());
        assert!(state.wave_session_clone().is_none());
    }

    fn test_session(batch_id: &str, radio_session_id: Option<&str>) -> Session {
        serde_json::from_value(serde_json::json!({
            "batchId": batch_id,
            "pumpkin": false,
            "radioSessionId": radio_session_id,
            "sequence": [],
            "terminated": false,
        }))
        .expect("test session JSON must deserialize")
    }

    #[test]
    fn set_wave_session_keeps_radio_id_when_response_misses_it() {
        let state = FetchState::new();
        state.set_wave_session(test_session("b1", Some("sess-1")));

        // A /tracks response with a null radioSessionId must not wipe the
        // last good one: batch rotates, but the session id is stable.
        state.set_wave_session(test_session("b2", None));

        let stored = state.wave_session_clone().expect("session stored");
        assert_eq!(stored.radio_session_id.as_deref(), Some("sess-1"));
        assert_eq!(stored.batch_id, "b2");
        assert!(is_usable_wave_session(&stored));
    }

    #[test]
    fn wave_page_does_not_replace_stored_session() {
        use crate::util::track::test_track;

        let state = FetchState::new();
        state.set_wave_session(test_session("b1", Some("sess-1")));

        // A page response only extends the per-track batch map; the stored
        // (created) session keeps its batch and radio id.
        let page_tracks = vec![test_track("t1"), test_track("t2")];
        state.remember_wave_batch("b2", &page_tracks);

        let stored = state.wave_session_clone().expect("session stored");
        assert_eq!(stored.batch_id, "b1");
        assert_eq!(stored.radio_session_id.as_deref(), Some("sess-1"));
        assert_eq!(state.wave_batch_for("t1").as_deref(), Some("b2"));
        assert_eq!(state.wave_batch_for("t2").as_deref(), Some("b2"));
        // Unknown tracks fall back to the stored session batch.
        assert_eq!(state.wave_batch_for("t9").as_deref(), Some("b1"));
    }

    #[test]
    fn reset_clears_batch_map() {
        use crate::util::track::test_track;

        let state = FetchState::new();
        state.set_wave_session(test_session("b1", Some("sess-1")));
        state.remember_wave_batch("b2", &[test_track("t1")]);
        assert_eq!(state.wave_batch_for("t1").as_deref(), Some("b2"));

        let mut state = state;
        state.reset();
        assert!(state.wave_batch_for("t1").is_none());
    }
}
