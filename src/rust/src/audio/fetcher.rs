use crate::http::{ApiService, SessionExt};
use crate::util::reactive::Signal;
use chrono::Utc;
use im::Vector;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinHandle;
use tracing::error;
use yandex_music::model::rotor::feedback::{StationFeedback, StationFeedbackEvent};
use yandex_music::model::rotor::session::Session;
use yandex_music::model::track::Track;

pub const FETCH_BATCH_SIZE: usize = 50;
pub const WAVE_VISIBLE_TRACKS: usize = 3;

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
    pub total_played: Duration,
    pub track_length: Option<Duration>,
    pub outcome: WaveTrackOutcome,
}

pub struct FetchState {
    pub task: Option<JoinHandle<FetchTaskResult>>,
    pub pending_track_ids: Vec<String>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
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

    pub fn set_wave_session(&self, mut session: Session) {
        let mut guard = self.wave_session.lock();
        if session.wave.is_none()
            && let Some(prev_wave) = guard.as_ref().and_then(|s| s.wave.clone())
        {
            session.wave = Some(prev_wave);
        }
        *guard = Some(session);
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
            let feedbacks: Vec<StationFeedback> = pending_feedback
                .into_iter()
                .map(|e| StationFeedback {
                    batch_id: Some(session.batch_id.clone()),
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
                    }
                }
                Err(e) => {
                    error!(error = %e, "wave_fetch_failed");
                    FetchTaskResult::Wave {
                        result: Err(e.to_string()),
                    }
                }
            }
        }));
        Ok(())
    }

    pub async fn await_task(&mut self) -> Option<(Vec<Track>, Option<Session>)> {
        self.await_task_timeout(Duration::from_secs(30)).await
    }

    /// Bounded wait for the in-flight fetch so the audio actor never blocks
    /// on a ~30s network fetch. On timeout the task handle is kept and the
    /// result is picked up later via poll_fetch().
    pub async fn await_task_timeout(
        &mut self,
        timeout: Duration,
    ) -> Option<(Vec<Track>, Option<Session>)> {
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

    async fn await_task_inner(&mut self) -> Option<(Vec<Track>, Option<Session>)> {
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
                    Some((tracks, None))
                }
                Err(error) => {
                    error!(error = %error, "track_fetch_failed");
                    if self.playlist_failure_requeues == 0 {
                        self.pending_track_ids.splice(0..0, ids);
                        self.playlist_failure_requeues = 1;
                    }
                    Some((vec![], None))
                }
            },
            FetchTaskResult::Wave { result } => {
                self.playlist_failure_requeues = 0;
                Some(result.map_or((vec![], None), |(tracks, session)| (tracks, Some(session))))
            }
        }
    }
}

pub struct WaveExtensionHandles {
    pub queue: Signal<Vector<Track>>,
    pub queue_length: Signal<usize>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
    pub playback_context: Arc<Mutex<crate::audio::queue::PlaybackContext>>,
    pub generation: u64,
    pub generation_ref: Arc<std::sync::atomic::AtomicU64>,
}

impl WaveExtensionHandles {
    /// Apply only if no load()/clear() happened since the task was spawned.
    pub fn apply(self, additional: Vector<Track>, session: Session) {
        if self
            .generation_ref
            .load(std::sync::atomic::Ordering::Relaxed)
            != self.generation
        {
            return;
        }
        *self.wave_session.lock() = Some(session.clone());
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
}
