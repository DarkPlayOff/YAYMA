use super::enums::RepeatMode;
use super::signals::AudioSignals;
use crate::audio::cache::UrlCache;
use crate::audio::progress::TrackProgress;
use crate::audio::stream_manager::StreamManager;
use crate::http::ApiService;
use crate::util::reactive::Signal;
use crate::util::track::extract_ids;
use im::Vector;
use parking_lot::Mutex;
use std::collections::VecDeque;
use std::sync::Arc;
use tracing::error;

use yandex_music::model::{
    album::Album, artist::Artist, playlist::Playlist, rotor::session::Session, track::Track,
};

use crate::audio::fetcher::{
    FetchState, WAVE_VISIBLE_TRACKS, WaveExtensionHandles, WaveTrackEvent, WaveTrackOutcome,
};
use crate::audio::history::HistoryState;
use crate::audio::prefetcher::UrlPrefetcher;
use crate::audio::shuffle::ShuffleState;

const URL_PREFETCH_WINDOW: usize = 5;
// Keep a reasonably sized playback window ahead of the current item.  The
// fetcher loads 50 tracks at a time, so starting a request with ten items left
// gives the request enough time to complete without making initial playlist
// loading wait for the whole playlist.
const FETCH_THRESHOLD: usize = 10;

#[derive(Debug, Clone, PartialEq)]
pub enum PlaybackContext {
    Playlist(Playlist),
    Artist(Artist),
    Album(Album),
    Track(Box<Track>),
    Wave(Session),
    Standalone,
}

struct PlaybackPolicy;

impl PlaybackPolicy {
    fn try_advance(current: usize, queue_len: usize) -> Option<usize> {
        let next = current + 1;
        if next < queue_len { Some(next) } else { None }
    }

    fn repeat_wrap_index(repeat: RepeatMode, queue_len: usize) -> Option<usize> {
        if repeat == RepeatMode::All && queue_len > 0 {
            Some(0)
        } else {
            None
        }
    }

    fn prev_index(current: usize, queue_len: usize, repeat: RepeatMode) -> Option<usize> {
        if current > 0 {
            Some(current - 1)
        } else if repeat == RepeatMode::All && queue_len > 0 {
            Some(queue_len - 1)
        } else {
            None
        }
    }
}

#[derive(Clone)]
struct QueueSignals {
    inner: AudioSignals,
}

impl QueueSignals {
    fn new(inner: AudioSignals) -> Self {
        inner.set_queue(Vector::new(), Vector::new(), 0);
        inner.set_repeat_mode(RepeatMode::None);
        inner.set_shuffled(false);
        Self { inner }
    }

    fn queue(&self) -> Vector<Track> {
        self.inner.queue.with(|q| q.clone())
    }

    fn index(&self) -> usize {
        self.inner.queue_index.get()
    }

    fn repeat_mode(&self) -> RepeatMode {
        self.inner.repeat_mode.get()
    }

    fn is_shuffled(&self) -> bool {
        self.inner.is_shuffled.get()
    }

    fn set_queue(&self, queue: Vector<Track>) {
        let len = queue.len();
        self.inner.queue.set(queue);
        self.inner.queue_length.set(len);
    }

    fn set_history(&self, history: Vector<Track>) {
        self.inner.history.set(history);
    }

    fn set_index(&self, index: usize) {
        self.inner.queue_index.set(index);
    }

    fn set_repeat_mode(&self, mode: RepeatMode) {
        self.inner.repeat_mode.set(mode);
    }

    fn set_shuffled(&self, shuffled: bool) {
        self.inner.is_shuffled.set(shuffled);
    }

    fn set_wave_seeds(&self, seeds: Vec<String>) {
        self.inner.current_wave_seeds.set(seeds);
    }

    fn raw_queue_handle(&self) -> Signal<Vector<Track>> {
        self.inner.queue.clone()
    }

    fn raw_queue_length_handle(&self) -> Signal<usize> {
        self.inner.queue_length.clone()
    }
}

pub struct QueueManager {
    api: Arc<ApiService>,

    pub stream_manager: Arc<StreamManager>,
    url_prefetcher: UrlPrefetcher,

    signals: QueueSignals,

    playback_context: Arc<Mutex<PlaybackContext>>,

    shuffle: ShuffleState,

    history: HistoryState,

    fetch: FetchState,

    wave_buffer: VecDeque<Track>,
    wave_feedbacks: Vec<WaveTrackEvent>,
    wave_feedback_sent: bool,
    track_progress: Arc<TrackProgress>,
    /// Bumped on every load()/clear() to invalidate stale background tasks
    /// (wave_by_seed session creation).
    generation: Arc<std::sync::atomic::AtomicU64>,
}

impl QueueManager {
    pub fn new(
        api: Arc<ApiService>,
        url_cache: UrlCache,
        stream_manager: Arc<StreamManager>,
        signals: AudioSignals,
        track_progress: Arc<TrackProgress>,
    ) -> Self {
        let url_prefetcher = UrlPrefetcher::new(api.clone(), url_cache.clone());

        Self {
            api,
            stream_manager,
            url_prefetcher,
            signals: QueueSignals::new(signals),
            playback_context: Arc::new(Mutex::new(PlaybackContext::Standalone)),
            shuffle: ShuffleState::inactive(),
            history: HistoryState::empty(),
            fetch: FetchState::new(),
            wave_buffer: VecDeque::new(),
            wave_feedbacks: Vec::new(),
            wave_feedback_sent: false,
            track_progress,
            generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        }
    }

    pub fn wave_context(&self) -> Option<Session> {
        self.fetch.wave_session_clone()
    }

    pub fn in_wave(&self) -> bool {
        matches!(*self.playback_context.lock(), PlaybackContext::Wave(_))
    }

    pub async fn load(
        &mut self,
        context: PlaybackContext,
        tracks: Vector<Track>,
        mut start_index: usize,
    ) -> Option<Track> {
        self.fetch.reset();
        self.url_prefetcher.reset();
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        *self.playback_context.lock() = context;
        self.shuffle.reset();
        self.history.reset();
        self.wave_buffer.clear();
        self.wave_feedbacks.clear();
        self.wave_feedback_sent = false;
        self.signals.set_history(Vector::new());
        self.signals.set_shuffled(false);

        if start_index >= tracks.len() {
            start_index = 0;
        }

        let wave_seed = {
            let ctx = self.playback_context.lock();
            match &*ctx {
                PlaybackContext::Playlist(playlist) => {
                    self.signals.set_wave_seeds(Vec::new());
                    let all_track_ids = playlist
                        .tracks
                        .as_ref()
                        .map(extract_ids)
                        .unwrap_or_default();

                    // `tracks` is the fetched prefix; keep the full prefix so
                    // Prev can go back to tracks before start_index.
                    let loaded_count = tracks.len().min(all_track_ids.len());
                    if let Err(error) = self
                        .fetch
                        .set_pending_ids(all_track_ids.into_iter().skip(loaded_count).collect())
                    {
                        error!(?error, "pending_ids_update_failed");
                        return None;
                    }

                    self.signals.set_queue(tracks);
                    self.signals.set_index(start_index);
                    None
                }

                PlaybackContext::Artist(_)
                | PlaybackContext::Album(_)
                | PlaybackContext::Standalone => {
                    self.signals.set_wave_seeds(Vec::new());
                    self.signals.set_queue(tracks);
                    self.signals.set_index(start_index);
                    None
                }

                PlaybackContext::Wave(session) => {
                    let visible_count = 1 + WAVE_VISIBLE_TRACKS;
                    let visible: Vector<Track> =
                        tracks.iter().take(visible_count).cloned().collect();
                    let hidden: Vec<Track> = tracks.into_iter().skip(visible_count).collect();

                    self.signals.set_queue(visible);
                    self.signals.set_index(start_index.min(visible_count.saturating_sub(1).max(0)));
                    for t in hidden {
                        self.wave_buffer.push_back(t);
                    }
                    self.fetch.set_wave_session(session.clone());
                    None
                }

                PlaybackContext::Track(seed_track) => {
                    self.signals.set_wave_seeds(vec![format!(
                        "track:{}:{}",
                        seed_track.id,
                        seed_track.title.as_deref().unwrap_or("Unknown")
                    )]);
                    let mut initial_queue = Vector::new();
                    initial_queue.push_back((**seed_track).clone());
                    self.signals.set_queue(initial_queue);

                    let needs_init = seed_track.track_source.as_ref().is_none_or(|s| s != "UGC");
                    if needs_init {
                        Some((**seed_track).clone())
                    } else {
                        None
                    }
                }
            }
        };

        if let Some(seed_track) = wave_seed {
            self.wave_by_seed(&seed_track);
        }

        let start = self.signals.index();
        let track = self.signals.queue().get(start).cloned();
        if let Some(t) = &track {
            self.commit_track_to_history(t.clone());
            self.update_prefetch_interest();
        }
        track
    }

    fn wave_by_seed(&self, seed_track: &Track) {
        let track_id = seed_track.id.clone();
        let generation = self.generation.load(std::sync::atomic::Ordering::Relaxed);
        let generation_ref = self.generation.clone();

        let api = self.api.clone();
        let handles = WaveExtensionHandles {
            queue: self.signals.raw_queue_handle(),
            queue_length: self.signals.raw_queue_length_handle(),
            wave_session: self.fetch.wave_session_arc(),
            playback_context: self.playback_context.clone(),
            generation,
            generation_ref,
        };

        tokio::spawn(async move {
            let Ok(session) = api.create_session(vec![format!("track:{track_id}")]).await else {
                return;
            };

            let additional: Vector<Track> =
                session.sequence.iter().map(|s| s.track.clone()).collect();

            if !additional.is_empty() {
                handles.apply(additional, session);
            }
        });
    }

    pub async fn get_next_track(&mut self) -> Option<Track> {
        if self.signals.queue().is_empty() {
            return None;
        }

        if self.signals.repeat_mode() == RepeatMode::Single {
            return self.signals.queue().get(self.signals.index()).cloned();
        }

        self.poll_fetch().await;

        let current = self.signals.index();
        let queue_len = self.signals.queue().len();
        let is_wave = self.in_wave();

        if !is_wave && current + 1 + FETCH_THRESHOLD >= queue_len {
            self.trigger_fetch();
        }

        if let Some(track) = self.try_advance_or_fetch(current).await {
            return Some(track);
        }

        if let Some(wrap) = PlaybackPolicy::repeat_wrap_index(
            self.signals.repeat_mode(),
            self.signals.queue().len(),
        ) {
            return self.advance_to(wrap);
        }

        None
    }

    pub fn get_previous_track(&mut self) -> Option<Track> {
        let prev = PlaybackPolicy::prev_index(
            self.signals.index(),
            self.signals.queue().len(),
            self.signals.repeat_mode(),
        )?;
        self.advance_to(prev)
    }

    async fn try_advance_or_fetch(&mut self, current: usize) -> Option<Track> {
        let queue_len = self.signals.queue().len();
        if let Some(next) = PlaybackPolicy::try_advance(current, queue_len) {
            return self.advance_to(next);
        }

        // Bounded wait: never park the audio actor on a ~30s network fetch.
        // On timeout the fetch stays in flight and poll_fetch() reaps it;
        // the caller treats None as queue end for now.
        if self.fetch.is_fetching()
            && let Some((new_tracks, session)) = self
                .fetch
                .await_task_timeout(std::time::Duration::from_secs(5))
                .await
        {
            if let Some(session) = session {
                self.fetch.set_wave_session(session);
            }
            if !new_tracks.is_empty() {
                self.wave_append(new_tracks);
                let queue_len = self.signals.queue().len();
                if let Some(next) = PlaybackPolicy::try_advance(current, queue_len) {
                    return self.advance_to(next);
                }
            }
        }
        None
    }

    pub async fn skip_wave_track(&mut self) -> Option<Track> {
        if self.in_wave() && !self.wave_feedback_sent {
            if let Some(track) = self.signals.queue().get(self.signals.index()).cloned() {
                self.wave_feedbacks.push(WaveTrackEvent {
                    track_id: as_wave_seed(&track),
                    outcome: WaveTrackOutcome::Skipped,
                    total_played: self.track_progress.current_position(),
                    track_length: None,
                });
                self.wave_feedback_sent = true;
            }
            self.wave_buffer.clear();
            if !self.fetch.is_fetching() {
                self.trigger_fetch();
            }
        }

        let current = self.signals.index();
        self.try_advance_or_fetch(current).await
    }

    pub fn wave_finish_track(&mut self) {
        if !self.in_wave() || self.wave_feedback_sent {
            return;
        }
        if let Some(track) = self.signals.queue().get(self.signals.index()).cloned() {
            let id = as_wave_seed(&track);
            if self.wave_feedbacks.iter().any(|e| e.track_id == id) {
                self.wave_feedback_sent = true;
                return;
            }
            self.wave_feedbacks.push(WaveTrackEvent {
                track_id: id,
                outcome: WaveTrackOutcome::Finished,
                total_played: self.track_progress.current_position(),
                track_length: track
                    .duration
                    .or_else(|| Some(self.track_progress.total_duration())),
            });
            self.wave_feedback_sent = true;
        }
    }

    pub fn refresh_wave_queue(&mut self) {
        if !self.in_wave() {
            return;
        }
        self.wave_buffer.clear();
        let current_index = self.signals.index();
        let mut queue = self.signals.queue();
        queue.truncate(current_index + 1);
        self.signals.set_queue(queue);

        if !self.fetch.is_fetching() {
            self.trigger_fetch();
        }
    }

    fn advance_to(&mut self, index: usize) -> Option<Track> {
        self.signals.set_index(index);
        self.wave_feedback_sent = false;
        let track = self.signals.queue().get(index).cloned()?;
        self.commit_track_to_history(track.clone());

        if self.in_wave() {
            let queue_len = self.signals.queue().len();
            let is_at_visible_tail = index + 1 >= queue_len;

            if is_at_visible_tail && let Some(next) = self.wave_buffer.pop_front() {
                let mut q = self.signals.queue();
                q.push_back(next);
                self.signals.set_queue(q);
            }

            let remaining = self.wave_buffer.len();
            if remaining <= 1 && !self.fetch.is_fetching() {
                self.trigger_fetch();
            }
        }

        // `advance_to` is also used by direct queue controls (for example
        // shuffle/next), not only by `get_next_track`.  Keep the lazy playlist
        // window topped up for those paths as well.
        if !self.in_wave()
            && index + FETCH_THRESHOLD + 1 >= self.signals.queue().len()
            && !self.fetch.is_fetching()
        {
            self.trigger_fetch();
        }

        self.update_prefetch_interest();
        Some(track)
    }

    pub fn queue_track(&mut self, track: Track) {
        let mut queue = self.signals.queue();
        let current_index = self.signals.index();

        let insert_at = if queue.is_empty() {
            0
        } else {
            current_index + 1
        };

        if insert_at <= queue.len() {
            queue.insert(insert_at, track);
            self.signals.set_queue(queue);
            self.shuffle.record_inserted(insert_at);
        }
        self.update_prefetch_interest();
    }

    pub fn play_next(&mut self, track: Track) {
        self.queue_track(track);
    }

    pub fn remove_track(&mut self, index: usize) {
        let mut queue = self.signals.queue();
        if index >= queue.len() {
            return;
        }
        queue.remove(index);
        self.signals.set_queue(queue);
        self.shuffle.record_removed(index);

        let current_index = self.signals.index();
        if index < current_index {
            self.signals.set_index(current_index.saturating_sub(1));
        } else if index == current_index {
            let len = self.signals.queue().len();
            if len == 0 {
                self.signals.set_index(0);
            } else if current_index >= len {
                self.signals.set_index(len - 1);
            }
        }
        self.update_prefetch_interest();
    }

    pub fn clear(&mut self) {
        self.fetch.reset();
        self.url_prefetcher.reset();
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.signals.set_queue(Vector::new());
        self.signals.set_index(0);
        self.signals.set_history(Vector::new());
        self.signals.set_repeat_mode(RepeatMode::None);
        self.signals.set_shuffled(false);
        self.signals.set_wave_seeds(Vec::new());
        self.signals.inner.set_stream_info(None);

        self.shuffle.reset();
        self.history.reset();
        self.wave_buffer.clear();
        self.wave_feedbacks.clear();
        self.wave_feedback_sent = false;
        *self.playback_context.lock() = PlaybackContext::Standalone;

        self.update_prefetch_interest();
    }

    fn fetch_wave_session_clone(&self) -> Option<Session> {
        self.fetch.wave_session_clone()
    }

    fn trigger_fetch(&mut self) {
        if self.fetch.is_fetching() {
            return;
        }

        if !self.fetch.pending_track_ids.is_empty() {
            if let Err(error) = self.fetch.trigger_playlist_batch(self.api.clone()) {
                error!(?error, "playlist_fetch_trigger_failed");
            }
            return;
        }

        if self.fetch_wave_session_clone().is_some() {
            let history_seeds = self.build_wave_history_seeds();
            let pending_feedback = std::mem::take(&mut self.wave_feedbacks);
            if let Err(error) =
                self.fetch
                    .trigger_wave_batch(self.api.clone(), history_seeds, pending_feedback)
            {
                error!(?error, "wave_fetch_trigger_failed");
            }
        }
    }

    fn build_wave_history_seeds(&self) -> Vec<String> {
        let played = self.history.entries.iter().rev().take(20).map(as_wave_seed);

        let queue = self.signals.queue();
        let not_yet_played = queue
            .iter()
            .skip(self.signals.index() + 1)
            .map(as_wave_seed);

        let buffered = self.wave_buffer.iter().map(as_wave_seed);

        played.chain(not_yet_played).chain(buffered).collect()
    }

    pub async fn poll_fetch(&mut self) {
        if self.fetch.is_finished() {
            self.consume_fetch_result().await;
        }
    }

    async fn consume_fetch_result(&mut self) -> bool {
        let Some((tracks, session)) = self.fetch.await_task().await else {
            return false;
        };

        if let Some(session) = session {
            self.fetch.set_wave_session(session);
        }

        if tracks.is_empty() {
            return false;
        }

        self.wave_append(tracks);
        true
    }

    fn wave_append(&mut self, tracks: Vec<Track>) {
        if self.in_wave() {
            let mut known_ids: std::collections::HashSet<String> =
                self.signals.queue().iter().map(|t| t.id.clone()).collect();
            known_ids.extend(self.wave_buffer.iter().map(|t| t.id.clone()));

            for track in tracks {
                if !known_ids.insert(track.id.clone()) {
                    continue;
                }
                let current_index = self.signals.index();
                let queue_len = self.signals.queue().len();
                let visible_ahead = queue_len.saturating_sub(current_index + 1);

                if visible_ahead < WAVE_VISIBLE_TRACKS {
                    let mut q = self.signals.queue();
                    q.push_back(track);
                    self.signals.set_queue(q);
                } else {
                    self.wave_buffer.push_back(track);
                }
            }
        } else {
            let mut queue = self.signals.queue();
            queue.extend(tracks);
            self.signals.set_queue(queue);
        }

        self.update_prefetch_interest();
    }

    fn update_prefetch_interest(&self) {
        let queue = self.signals.queue();
        if queue.is_empty() {
            return;
        }

        let current_index = self.signals.index();
        let current_id = queue.get(current_index).map(|t| t.id.clone());

        if let Some(next_track) = queue.get(current_index + 1) {
            self.stream_manager.prewarm(next_track.clone());
        }

        // Division of labor with prewarm above: a ready decode session
        // already resolved + cached this track's URL, so don't spend a URL
        // batch slot on it. (In-flight prewarm is NOT excluded: if it fails,
        // the URL prefetch is the fallback that keeps the start fast.)
        let needed: Vec<String> = (0..URL_PREFETCH_WINDOW)
            .filter_map(|i| queue.get(current_index + i))
            .map(|t| t.id.clone())
            .filter(|id| !self.stream_manager.has_prewarm_ready(id))
            .collect();

        self.url_prefetcher.update(needed, current_id);
    }

    fn commit_track_to_history(&mut self, track: Track) {
        self.history.push(track);
        self.signals.set_history(self.history.as_vector());
    }

    pub fn toggle_repeat_mode(&mut self) {
        let new_mode = match self.signals.repeat_mode() {
            RepeatMode::None => RepeatMode::All,
            RepeatMode::All => RepeatMode::Single,
            RepeatMode::Single => RepeatMode::None,
        };
        self.signals.set_repeat_mode(new_mode);
        self.signals.inner.changed.send_replace(());
    }

    pub fn toggle_shuffle(&mut self) {
        if self.signals.is_shuffled() {
            let current_index = self.signals.index();
            if let Some((original_queue, restored_index)) = self.shuffle.disable(current_index) {
                self.signals.set_queue(original_queue);
                self.signals.set_index(restored_index);
            }
            self.signals.set_shuffled(false);
        } else {
            let queue = self.signals.queue();
            let current_index = self.signals.index();
            let (shuffled_queue, new_index) = self.shuffle.enable(queue, current_index);
            self.signals.set_queue(shuffled_queue);
            self.signals.set_index(new_index);
            self.signals.set_shuffled(true);
        }
        self.signals.inner.changed.send_replace(());
        self.update_prefetch_interest();
    }
}

pub fn as_wave_seed(track: &Track) -> String {
    if let Some(album_id) = track.albums.first().and_then(|a| a.id.as_ref()) {
        format!("{}:{}", track.id, album_id)
    } else {
        track.id.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::cache::UrlCache;
    use crate::audio::signals::AudioSignals;
    use crate::storage::cache::TrackCache;
    use crate::util::track::test_track;

    async fn manager() -> QueueManager {
        let api = Arc::new(
            crate::http::ApiService::new("test-token".to_string(), Some(12345))
                .await
                .expect("api builds offline"),
        );
        let url_cache = UrlCache::new();
        let track_cache = Arc::new(TrackCache::new(None));
        let stream_manager = Arc::new(StreamManager::new(
            api.clone(),
            url_cache.clone(),
            track_cache,
        ));
        QueueManager::new(
            api,
            url_cache,
            stream_manager,
            AudioSignals::new(),
            Arc::new(TrackProgress::default()),
        )
    }

    fn standalone(n: usize) -> Vector<Track> {
        (0..n).map(|i| test_track(&format!("t{i}"))).collect()
    }

    #[tokio::test]
    async fn load_keeps_prefix_so_prev_works_from_middle() {
        let mut q = manager().await;
        let first = q
            .load(PlaybackContext::Standalone, standalone(5), 2)
            .await
            .expect("load returns start track");
        assert_eq!(first.id, "t2");
        // Regression test for slice_from: tracks before start_index survive.
        let prev = q.get_previous_track().expect("prev exists");
        assert_eq!(prev.id, "t1");
        let next = q.get_next_track().await.expect("next exists");
        assert_eq!(next.id, "t2");
    }

    #[tokio::test]
    async fn next_advances_and_ends_at_tail() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 0).await;
        assert_eq!(q.get_next_track().await.unwrap().id, "t1");
        assert_eq!(q.get_next_track().await.unwrap().id, "t2");
        assert!(q.get_next_track().await.is_none());
    }

    #[tokio::test]
    async fn repeat_all_wraps_around() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(2), 1).await;
        q.toggle_repeat_mode(); // None -> All
        assert_eq!(q.get_next_track().await.unwrap().id, "t0");
    }

    #[tokio::test]
    async fn remove_current_track_stays_navigable() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 1).await;
        q.remove_track(1); // remove "t1" under the cursor
        // Cursor clamps into range: prev/next must not panic or dangle.
        let prev = q.get_previous_track().expect("prev exists");
        assert_eq!(prev.id, "t0");
        assert!(q.get_next_track().await.is_some());
    }

    #[tokio::test]
    async fn clear_empties_queue() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 0).await;
        q.clear();
        assert!(q.get_next_track().await.is_none());
        assert!(q.get_previous_track().is_none());
    }

    #[tokio::test]
    async fn shuffle_roundtrip_restores_walk_order() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(4), 0).await;
        q.toggle_shuffle();
        q.toggle_shuffle();
        assert_eq!(q.get_next_track().await.unwrap().id, "t1");
        assert_eq!(q.get_next_track().await.unwrap().id, "t2");
    }
}
