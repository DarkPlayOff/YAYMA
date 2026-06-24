use crate::audio::events::Event;
use crate::http::{ApiService, SessionExt};
use crate::util::reactive::Signal;
use chrono::Utc;
use flume::Sender;
use im::Vector;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinHandle;
use tracing::error;
use yandex_music::model::rotor::feedback::{StationFeedback, StationFeedbackEvent};
use yandex_music::model::rotor::session::Session;
use yandex_music::model::track::Track;

pub const FETCH_BATCH_SIZE: usize = 10;
pub const WAVE_VISIBLE_TRACKS: usize = 3;

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
    pub task: Option<JoinHandle<(Vec<Track>, Option<Session>)>>,
    pub pending_track_ids: Vec<String>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
}

impl Clone for FetchState {
    fn clone(&self) -> Self {
        Self {
            task: None, // JoinHandle cannot be cloned
            pending_track_ids: self.pending_track_ids.clone(),
            wave_session: self.wave_session.clone(),
        }
    }
}

impl FetchState {
    pub fn new() -> Self {
        Self {
            task: None,
            pending_track_ids: Vec::new(),
            wave_session: Arc::new(Mutex::new(None)),
        }
    }

    pub fn reset(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
        self.pending_track_ids.clear();
        *self.wave_session.lock() = None;
    }

    pub fn set_pending_ids(&mut self, ids: Vec<String>) {
        debug_assert!(
            self.pending_track_ids.is_empty(),
            "set_pending_ids called with non-empty list; call reset() first"
        );
        self.pending_track_ids = ids;
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

    pub fn trigger_playlist_batch(&mut self, api: Arc<ApiService>, event_tx: Option<Sender<Event>>) {
        debug_assert!(!self.is_fetching());
        let count = FETCH_BATCH_SIZE.min(self.pending_track_ids.len());
        let ids: Vec<String> = self.pending_track_ids.drain(0..count).collect();

        self.task = Some(tokio::spawn(async move {
            match api.fetch_tracks(ids).await {
                Ok(tracks) => {
                    let valid: Vec<Track> = tracks
                        .into_iter()
                        .filter(|t| t.available.unwrap_or(false))
                        .collect();
                    if !valid.is_empty()
                        && let Some(tx) = event_tx
                    {
                        let _ = tx.send(Event::QueueUpdated);
                    }
                    (valid, None)
                }
                Err(e) => {
                    error!(error = %e, "track_fetch_failed");
                    (vec![], None)
                }
            }
        }));
    }

    pub fn trigger_wave_batch(
        &mut self,
        api: Arc<ApiService>,
        event_tx: Option<Sender<Event>>,
        wave_seeds: Vec<String>,
        pending_feedback: Vec<WaveTrackEvent>,
    ) {
        debug_assert!(!self.is_fetching());
        let session = match self.wave_session_clone() {
            Some(s) => s,
            None => return,
        };
        let session_id = session.radio_session_id.clone().unwrap_or_default();

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
                    if !new_tracks.is_empty()
                        && let Some(tx) = event_tx
                    {
                        let _ = tx.send(Event::QueueUpdated);
                    }
                    (new_tracks, Some(response))
                }
                Err(e) => {
                    error!(error = %e, "wave_fetch_failed");
                    (vec![], None)
                }
            }
        }));
    }

    pub async fn await_task(&mut self) -> Option<(Vec<Track>, Option<Session>)> {
        let task = self.task.take()?;
        (task.await).ok()
    }
}

pub struct WaveExtensionHandles {
    pub queue: Signal<Vector<Track>>,
    pub queue_length: Signal<usize>,
    pub wave_session: Arc<Mutex<Option<Session>>>,
    pub playback_context: Arc<Mutex<crate::audio::queue::PlaybackContext>>,
    pub event_tx: Option<Sender<Event>>,
}

impl WaveExtensionHandles {
    pub fn apply(self, additional: Vector<Track>, session: Session) {
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

        if let Some(tx) = self.event_tx.clone() {
            let _ = tx.send(Event::QueueUpdated);
        }

        let hidden: Vec<Track> = additional.into_iter().skip(WAVE_VISIBLE_TRACKS).collect();
        if !hidden.is_empty()
            && let Some(tx) = self.event_tx
        {
            let _ = tx.send(Event::WaveBuffer(hidden));
        }
    }
}
