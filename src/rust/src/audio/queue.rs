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
use tokio::sync::Notify;
use tracing::error;

use yandex_music::model::{
    album::Album, artist::Artist, playlist::Playlist, rotor::session::Session, track::Track,
};

use crate::audio::fetcher::{
    FetchState, WAVE_VISIBLE_TRACKS, WaveExtensionHandles, WaveTrackEvent, WaveTrackOutcome,
    is_usable_wave_session,
};
use crate::audio::history::HistoryState;
use crate::audio::prefetcher::UrlPrefetcher;
use crate::audio::shuffle::ShuffleState;

const URL_PREFETCH_WINDOW: usize = 5;
/// Unplayed rotor-generated tracks expire 30 minutes after they were fetched
/// (desktop beforeInject calibration), so stale recommendations never pile up.
const WAVE_TRACK_TTL: std::time::Duration = std::time::Duration::from_secs(30 * 60);
// Keep a reasonably sized playback window ahead of the current item.  The
// fetcher loads 50 tracks at a time, so starting a request with ten items left
// gives the request enough time to complete without making initial playlist
// loading wait for the whole playlist.
const FETCH_THRESHOLD: usize = 10;

/// Constructors for wave finish/skip feedback events.
/// `skip_wave_track` and `wave_finish_track` differed only in
/// `outcome`/`track_length`; both delegate here now.
mod wave_feedback {
    use super::Track;
    use super::WaveTrackEvent;
    use super::WaveTrackOutcome;

    pub(super) fn build_event(
        track: &Track,
        outcome: WaveTrackOutcome,
        batch_id: Option<String>,
        total_played: std::time::Duration,
        track_length: Option<std::time::Duration>,
    ) -> WaveTrackEvent {
        WaveTrackEvent {
            track_id: super::as_wave_seed(track),
            batch_id,
            outcome,
            total_played,
            track_length,
        }
    }
}

/// Pure fetch/prewarm decisions for `QueueManager`.
/// Orchestration (locks, signals, network triggers) stays in the thin
/// methods below; only branch conditions and window math live here so
/// they are testable without signals/streaming state.
mod fetch_policy {
    use super::HistoryState;
    use super::Track;
    use super::Vector;
    use super::WAVE_VISIBLE_TRACKS;
    use super::WaveTrackEvent;
    use super::as_wave_seed;

    /// The rotor `queue` dedup parameter carries up to the last 100 played
    /// vibe tracks ("trackId:albumId"), matching the desktop client.
    pub(super) const MAX_HISTORY_SEEDS: usize = 100;

    pub(super) fn history_seeds(history: &HistoryState) -> Vec<String> {
        let len = history.entries.len();
        history
            .entries
            .iter()
            .skip(len.saturating_sub(MAX_HISTORY_SEEDS))
            .map(as_wave_seed)
            .collect()
    }

    pub(super) fn playlist_needs_topup(
        is_wave: bool,
        current: usize,
        queue_len: usize,
        threshold: usize,
    ) -> bool {
        !is_wave && current + 1 + threshold >= queue_len
    }

    pub(super) fn advance_needs_playlist_topup(
        is_wave: bool,
        index: usize,
        queue_len: usize,
        threshold: usize,
        is_fetching: bool,
    ) -> bool {
        !is_wave && index + threshold + 1 >= queue_len && !is_fetching
    }

    /// How many buffered tracks to move into the visible window so that
    /// `current + WAVE_VISIBLE_TRACKS` are queued ahead, and whether a fetch
    /// is still needed after taking them.
    pub(super) fn wave_window_refill(ahead: usize, buffered: usize) -> (usize, bool) {
        let missing = WAVE_VISIBLE_TRACKS.saturating_sub(ahead);
        let take = missing.min(buffered);
        (take, take < missing)
    }

    // Pure split of `update_prefetch_interest`: window ids + next track.
    // Filtering against ready prewarm sessions stays with the caller
    // because it needs `StreamManager`.
    pub(super) fn prefetch_window(
        queue: &Vector<Track>,
        index: usize,
        window: usize,
    ) -> (Option<String>, Vec<String>, Option<Track>) {
        let current_id = queue.get(index).map(|t| t.id.clone());
        let next = queue.get(index + 1).cloned();
        let ids = (0..window)
            .filter_map(|i| queue.get(index + i))
            .map(|t| t.id.clone())
            .collect();
        (current_id, ids, next)
    }

    // Pure merge for failed page feedbacks: drop retries for tracks that
    // already have a queued event, prepend the rest.
    pub(super) fn merge_failed_feedbacks(
        pending: Vec<WaveTrackEvent>,
        failed: Vec<WaveTrackEvent>,
    ) -> Vec<WaveTrackEvent> {
        let mut fresh: Vec<WaveTrackEvent> = failed
            .into_iter()
            .filter(|e| !pending.iter().any(|q| q.track_id == e.track_id))
            .collect();
        fresh.extend(pending);
        fresh
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum PlaybackContext {
    Playlist(Playlist),
    Artist(Artist),
    Album(Album),
    Track(Box<Track>),
    Wave(Session),
    Standalone,
}

impl PlaybackContext {
    /// Bridge-facing projection of the active context; `title` is only set
    /// when the context carried one at load time.
    pub fn to_dto(&self) -> crate::api::models::PlaybackContextDto {
        let (kind, id, title) = match self {
            PlaybackContext::Playlist(p) => (
                "playlist",
                Some(p.kind.to_string()),
                Some(p.title.clone()),
            ),
            PlaybackContext::Artist(a) => ("artist", a.id.clone(), a.name.clone()),
            PlaybackContext::Album(a) => (
                "album",
                a.id.map(|i| i.to_string()),
                a.title.clone(),
            ),
            PlaybackContext::Track(t) => ("track", Some(t.id.clone()), t.title.clone()),
            PlaybackContext::Wave(s) => (
                "wave",
                Some(
                    s.radio_session_id
                        .clone()
                        .unwrap_or_else(|| s.batch_id.clone()),
                ),
                None,
            ),
            PlaybackContext::Standalone => ("standalone", None, None),
        };
        crate::api::models::PlaybackContextDto {
            kind: kind.to_string(),
            id,
            title,
        }
    }
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
        // Delegate to the inner notifying setters: a raw `.set()` would not
        // wake the bridge worker, and the UI would only see the change when
        // some other event (e.g. a track change) happened to notify.
        self.inner.set_history(history);
    }

    fn set_index(&self, index: usize) {
        self.inner.queue_index.set(index);
    }

    fn set_repeat_mode(&self, mode: RepeatMode) {
        self.inner.set_repeat_mode(mode);
    }

    fn set_shuffled(&self, shuffled: bool) {
        self.inner.set_shuffled(shuffled);
    }

    fn set_wave_seeds(&self, seeds: Vec<String>) {
        self.inner.set_wave_seeds(seeds);
    }

    fn set_playback_context(&self, context: &PlaybackContext) {
        self.inner
            .playback_context
            .set(Some(context.to_dto()));
    }

    /// Bumps the queue revision and wakes the bridge worker so queue edits
    /// reach the UI even when length and index are unchanged.
    fn bump_revision(&self) {
        self.inner
            .queue_revision
            .update(|revision| *revision = revision.wrapping_add(1));
        self.inner.changed.send_replace(());
    }

    fn wave_seeds(&self) -> Vec<String> {
        self.inner.current_wave_seeds.get()
    }

    fn raw_queue_handle(&self) -> Signal<Vector<Track>> {
        self.inner.queue.clone()
    }

    fn raw_queue_length_handle(&self) -> Signal<usize> {
        self.inner.queue_length.clone()
    }

    fn raw_queue_revision_handle(&self) -> Signal<u32> {
        self.inner.queue_revision.clone()
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
    /// Fetch timestamp per rotor-generated track id, for the 30-minute TTL.
    wave_fetch_times: foldhash::HashMap<String, std::time::Instant>,
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
            wave_fetch_times: foldhash::HashMap::default(),
            wave_feedbacks: Vec::new(),
            wave_feedback_sent: false,
            track_progress,
            generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        }
    }

    pub fn wave_context(&self) -> Option<Session> {
        self.fetch.wave_session_clone()
    }

    /// Clone of the active playback context for `/plays` attribution.
    pub fn playback_context(&self) -> PlaybackContext {
        self.playback_context.lock().clone()
    }

    pub fn in_wave(&self) -> bool {
        matches!(*self.playback_context.lock(), PlaybackContext::Wave(_))
    }

    pub fn fetch_finished(&self) -> Arc<Notify> {
        self.fetch.fetch_finished()
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

        *self.playback_context.lock() = context.clone();
        self.signals.set_playback_context(&context);
        // Shuffle is a player-level setting (desktop parity): it survives a
        // context switch and is re-applied to the freshly loaded queue below.
        // The wave queue is owned by the rotor session, so it never starts
        // shuffled.
        let keep_shuffled =
            self.signals.is_shuffled() && !matches!(context, PlaybackContext::Wave(_));
        self.shuffle.reset();
        self.history.reset();
        self.wave_buffer.clear();
        self.wave_fetch_times.clear();
        self.wave_feedbacks.clear();
        self.wave_feedback_sent = false;
        self.signals.set_history(Vector::new());
        self.signals.set_shuffled(keep_shuffled);

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

                    Self::install_loaded_queue(
                        &self.signals,
                        &mut self.shuffle,
                        tracks,
                        start_index,
                        keep_shuffled,
                    );
                    None
                }

                PlaybackContext::Artist(_)
                | PlaybackContext::Album(_)
                | PlaybackContext::Standalone => {
                    self.signals.set_wave_seeds(Vec::new());
                    Self::install_loaded_queue(
                        &self.signals,
                        &mut self.shuffle,
                        tracks,
                        start_index,
                        keep_shuffled,
                    );
                    None
                }

                PlaybackContext::Wave(session) => {
                    let visible_count = 1 + WAVE_VISIBLE_TRACKS;
                    let visible: Vector<Track> =
                        tracks.iter().take(visible_count).cloned().collect();
                    let hidden: Vec<Track> = tracks.into_iter().skip(visible_count).collect();

                    // Stamped directly (the context guard is held here).
                    let now = std::time::Instant::now();
                    for t in visible.iter().chain(hidden.iter()) {
                        self.wave_fetch_times.insert(t.id.clone(), now);
                    }

                    self.signals.set_queue(visible);
                    self.signals
                        .set_index(start_index.min(visible_count.saturating_sub(1).max(0)));
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
                    // A seed context transitions straight into rotor-owned
                    // territory, where shuffle does not apply.
                    self.signals.set_shuffled(false);
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

    /// Installs a freshly loaded queue; when shuffle survived the context
    /// switch, the new queue is rolled with its start track anchored first
    /// (the same semantics as enabling shuffle mid-playback). Takes the two
    /// fields it needs directly: callers run while the playback-context lock
    /// guard is held, so a `&mut self` method would conflict with it.
    fn install_loaded_queue(
        signals: &QueueSignals,
        shuffle: &mut ShuffleState,
        tracks: Vector<Track>,
        start_index: usize,
        shuffled: bool,
    ) {
        if shuffled {
            let (queue, index) = shuffle.enable(tracks, start_index);
            signals.set_queue(queue);
            signals.set_index(index);
            signals.set_shuffled(true);
        } else {
            signals.set_queue(tracks);
            signals.set_index(start_index);
            signals.set_shuffled(false);
        }
    }

    fn wave_by_seed(&self, seed_track: &Track) {
        let track_id = seed_track.id.clone();
        let generation = self.generation.load(std::sync::atomic::Ordering::Relaxed);
        let generation_ref = self.generation.clone();

        let api = self.api.clone();
        let handles = WaveExtensionHandles {
            queue: self.signals.raw_queue_handle(),
            queue_length: self.signals.raw_queue_length_handle(),
            queue_revision: self.signals.raw_queue_revision_handle(),
            wave_session: self.fetch.wave_session_arc(),
            wave_batch_ids: self.fetch.wave_batch_ids_arc(),
            playback_context: self.playback_context.clone(),
            playback_context_dto: self.signals.inner.playback_context.clone(),
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

    /// Next track after a natural end: under `RepeatMode::Single` the
    /// current track is returned again so it replays from the start.
    pub async fn get_next_track(&mut self) -> Option<Track> {
        self.next_track(false).await
    }

    /// The track the gapless preheat should park: the queue successor of the
    /// current track under the active repeat policy. Purely observational —
    /// nothing advances. `RepeatMode::Single` returns the current track so
    /// the parked preheat slot replays it instantly at the boundary.
    pub fn peek_gapless_next(&self) -> Option<Track> {
        let queue = self.signals.queue();
        if queue.is_empty() {
            return None;
        }
        let repeat = self.signals.repeat_mode();
        if repeat == RepeatMode::Single {
            return queue.get(self.signals.index()).cloned();
        }
        let next = self.signals.index() + 1;
        if next < queue.len() {
            queue.get(next).cloned()
        } else {
            PlaybackPolicy::repeat_wrap_index(repeat, queue.len())
                .and_then(|wrapped| queue.get(wrapped).cloned())
        }
    }

    /// Next track for a user-initiated skip: advances past the current
    /// track even when `RepeatMode::Single` is active.
    pub async fn skip_track(&mut self) -> Option<Track> {
        self.next_track(true).await
    }

    async fn next_track(&mut self, user_skip: bool) -> Option<Track> {
        if self.signals.queue().is_empty() {
            return None;
        }

        if self.in_wave()
            && self
                .fetch_wave_session_clone()
                .is_some_and(|s| s.terminated)
        {
            self.recreate_wave_session().await;
        }

        if !user_skip && self.signals.repeat_mode() == RepeatMode::Single {
            return self.signals.queue().get(self.signals.index()).cloned();
        }

        self.poll_fetch();

        let current = self.signals.index();
        let queue_len = self.signals.queue().len();
        let is_wave = self.in_wave();

        if fetch_policy::playlist_needs_topup(is_wave, current, queue_len, FETCH_THRESHOLD) {
            self.trigger_fetch();
        }

        // Buffered wave tracks must reach the visible queue before the
        // advance is attempted, or playback stops with music still buffered.
        self.refill_wave_window(false);

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
            && let Some((new_tracks, session, failed_feedbacks)) = self
                .fetch
                .await_task_timeout(std::time::Duration::from_secs(5))
                .await
        {
            self.requeue_failed_wave_feedbacks(failed_feedbacks);
            if let Some(session) = session {
                // Page response: keep the created session stable, only
                // remember which batch delivered these tracks.
                self.fetch
                    .remember_wave_batch(&session.batch_id, &new_tracks);
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
        if self.in_wave()
            && self
                .fetch_wave_session_clone()
                .is_some_and(|s| s.terminated)
        {
            self.recreate_wave_session().await;
        }
        if self.in_wave() && !self.wave_feedback_sent {
            if let Some(track) = self.signals.queue().get(self.signals.index()).cloned() {
                self.wave_feedbacks.push(wave_feedback::build_event(
                    &track,
                    WaveTrackOutcome::Skipped,
                    self.fetch.wave_batch_for(&track.id),
                    self.track_progress.current_position(),
                    None,
                ));
                self.wave_feedback_sent = true;
            }
        }

        let current = self.signals.index();
        // Keep the buffered upcoming tracks: a skip should send feedback for
        // the current track, not throw away pages already fetched. Only ask
        // for a page when the buffer cannot fill the visible window.
        self.refill_wave_window(true);
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
            self.wave_feedbacks.push(wave_feedback::build_event(
                &track,
                WaveTrackOutcome::Finished,
                self.fetch.wave_batch_for(&track.id),
                self.track_progress.current_position(),
                track
                    .duration
                    .or_else(|| Some(self.track_progress.total_duration())),
            ));
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
            self.prune_expired_wave_tracks();
            self.refill_wave_window(true);
        }

        // `advance_to` is also used by direct queue controls (for example
        // shuffle/next), not only by `get_next_track`.  Keep the lazy playlist
        // window topped up for those paths as well.
        if fetch_policy::advance_needs_playlist_topup(
            self.in_wave(),
            index,
            self.signals.queue().len(),
            FETCH_THRESHOLD,
            self.fetch.is_fetching(),
        ) {
            self.trigger_fetch();
        }

        self.update_prefetch_interest();
        Some(track)
    }

    /// Shared tail of the queue-insert operations.
    fn insert_into_queue(&mut self, track: Track, insert_at: usize) {
        let mut queue = self.signals.queue();
        if insert_at <= queue.len() {
            queue.insert(insert_at, track);
            self.signals.set_queue(queue);
            self.shuffle.record_inserted(insert_at);
        }
        self.signals.bump_revision();
        self.refill_wave_window(true);
        self.update_prefetch_interest();
    }

    /// "Add to queue": appends at the end. In a wave context the rotor tail
    /// lives in the buffer, so the track pins right after the visible window
    /// (current + WAVE_VISIBLE_TRACKS) instead of the absolute end.
    pub fn queue_track(&mut self, track: Track) {
        let queue = self.signals.queue();
        let insert_at = if queue.is_empty() {
            0
        } else if self.in_wave() {
            (self.signals.index() + 1 + WAVE_VISIBLE_TRACKS).min(queue.len())
        } else {
            queue.len()
        };
        self.insert_into_queue(track, insert_at);
    }

    /// "Play next": inserts right after the current track, in wave contexts too.
    pub fn play_next(&mut self, track: Track) {
        let insert_at = if self.signals.queue().is_empty() {
            0
        } else {
            self.signals.index() + 1
        };
        self.insert_into_queue(track, insert_at);
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
        self.signals.bump_revision();
        self.refill_wave_window(true);
        self.update_prefetch_interest();
    }

    /// Moves the entry at `from` to `to` in the active (visible) order. Under
    /// shuffle the user's arrangement sticks: the original-queue mapping is
    /// reordered alongside. The cursor follows so the currently playing track
    /// keeps playing seamlessly when it is the one being moved.
    pub fn reorder(&mut self, from: usize, to: usize) {
        let mut queue = self.signals.queue();
        if from == to || from >= queue.len() || to >= queue.len() {
            return;
        }
        let current_index = self.signals.index();
        let current_id = queue.get(current_index).map(|t| t.id.clone());

        let track = queue.remove(from);
        queue.insert(to, track);

        let new_index = if from == current_index {
            to
        } else if from < current_index && to >= current_index {
            current_index - 1
        } else if from > current_index && to <= current_index {
            current_index + 1
        } else {
            current_index
        };

        self.signals.set_queue(queue);
        self.shuffle.record_reorder(from, to);
        self.signals.set_index(new_index);

        // The playing track must not change identity across a reorder.
        debug_assert_eq!(
            self.signals.queue().get(new_index).map(|t| t.id.clone()),
            current_id
        );

        self.signals.bump_revision();
        self.refill_wave_window(true);
        self.update_prefetch_interest();
    }

    /// Jumps to the queue entry at `index` and returns it for playback. Under
    /// shuffle the order is re-rolled anchored on the target track (the
    /// desktop behaviour: the target becomes the first upcoming track).
    pub fn jump_to(&mut self, index: usize) -> Option<Track> {
        let queue_len = self.signals.queue().len();
        if queue_len == 0 {
            return None;
        }
        let index = index.min(queue_len - 1);
        if self.signals.is_shuffled() {
            let queue = self.signals.queue();
            let (shuffled, new_index) = self.shuffle.reroll_anchored(queue, index);
            self.signals.set_queue(shuffled);
            self.signals.set_index(new_index);
            self.advance_to(new_index)
        } else {
            self.advance_to(index)
        }
    }

    pub fn clear(&mut self) {
        self.fetch.reset();
        self.url_prefetcher.reset();
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.signals.set_queue(Vector::new());
        self.signals.set_index(0);
        self.signals.set_history(Vector::new());
        // Repeat/shuffle are player-level settings: they survive clearing and
        // re-apply to whatever plays next (clear() also runs on Stop).
        self.signals.set_wave_seeds(Vec::new());
        self.signals.inner.set_stream_info(None);

        self.shuffle.reset();
        self.history.reset();
        self.wave_buffer.clear();
        self.wave_fetch_times.clear();
        self.wave_feedbacks.clear();
        self.wave_feedback_sent = false;
        *self.playback_context.lock() = PlaybackContext::Standalone;
        self.signals.set_playback_context(&PlaybackContext::Standalone);

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

        if let Some(session) = self.fetch_wave_session_clone() {
            if session.terminated {
                // Dead session: paging/feedback on it is rejected by the
                // server. Recreate happens in the async next/skip paths
                // (sync context can't await create_session); don't spam
                // doomed page requests or lose feedbacks here.
                return;
            }
            if !is_usable_wave_session(&session) {
                // No radio_session_id (and preservation had nothing to keep):
                // trigger_wave_batch would just drop our finish/skip events
                // with MissingWaveSession, so don't take them.
                error!("wave_fetch_trigger_failed_no_session_id");
                return;
            }
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

    /// Recreate a terminated wave session with the same seeds so a custom
    /// station survives instead of falling back to `user:onyourwave`.
    /// Buffered tracks stay playable; stale finish/skip events belong to the
    /// dead batch and are dropped so they can't 400 the new session.
    async fn recreate_wave_session(&mut self) {
        if self.fetch.is_fetching() {
            return;
        }
        let seeds = self.signals.wave_seeds();
        let seeds = if seeds.is_empty() {
            vec!["user:onyourwave".to_string()]
        } else {
            seeds
        };
        let clean: Vec<String> = seeds.iter().map(|s| clean_wave_seed(s)).collect();
        match self.api.create_session(clean).await {
            Ok(session) => {
                let tracks: Vec<Track> = session.sequence.iter().map(|s| s.track.clone()).collect();
                if tracks.is_empty() {
                    error!("wave_session_recreate_empty");
                    return;
                }
                self.fetch.set_wave_session(session);
                self.wave_feedbacks.clear();
                self.wave_append(tracks);
            }
            Err(e) => error!(error = %e, "wave_session_recreate_failed"),
        }
    }

    /// `queue` for the next `/tracks` page mirrors the original client: the
    /// played history (oldest → newest, capped) — NOT the upcoming queue or
    /// the prefetch buffer. Sending future tracks as `queue` confuses the
    /// recommender and contributes to wave resets.
    fn build_wave_history_seeds(&self) -> Vec<String> {
        fetch_policy::history_seeds(&self.history)
    }

    /// Prepend failed page feedbacks so they are retried with the next page.
    /// Events for tracks that already have a queued event are dropped (the
    /// original client dedups finish/skip per track the same way).
    fn requeue_failed_wave_feedbacks(&mut self, failed: Vec<WaveTrackEvent>) {
        if failed.is_empty() {
            return;
        }
        self.wave_feedbacks =
            fetch_policy::merge_failed_feedbacks(std::mem::take(&mut self.wave_feedbacks), failed);
    }

    /// Per-track `batchId` for immediate (`/feedback`) wave feedbacks.
    pub fn wave_batch_for_track(&self, track: &Track) -> Option<String> {
        self.fetch.wave_batch_for(&track.id)
    }

    /// Same as above for call sites that only have a raw track id.
    pub fn wave_batch_for_id(&self, track_id: &str) -> Option<String> {
        self.fetch.wave_batch_for(track_id)
    }

    /// Consumes a page that the fetch task already delivered.
    /// Returns `true` if it added tracks.
    pub fn poll_fetch(&mut self) -> bool {
        let Some((tracks, session, failed_feedbacks)) = self.fetch.try_take_page() else {
            return false;
        };
        self.requeue_failed_wave_feedbacks(failed_feedbacks);

        if let Some(session) = session {
            // Page response, not a new session: the created session stays
            // stable, only per-track batch attribution is updated.
            self.fetch.remember_wave_batch(&session.batch_id, &tracks);
        }

        if tracks.is_empty() {
            return false;
        }

        self.wave_append(tracks);
        true
    }

    /// Whether the visible wave window has no track after the current one.
    pub fn has_no_visible_next(&self) -> bool {
        self.signals.queue().len() <= self.signals.index() + 1
    }

    /// Keeps the visible window (current + `WAVE_VISIBLE_TRACKS`) full by
    /// draining buffered wave tracks, and asks for the next page when the
    /// buffer cannot fill it. Called after every advance and when a batch
    /// completes, so the upcoming tracks (and the cover carousel that reads
    /// them) are visible while the current track is still playing.
    pub fn refill_wave_window(&mut self, allow_fetch: bool) {
        if !self.in_wave() {
            return;
        }
        let index = self.signals.index();
        let mut queue = self.signals.queue();
        let ahead = queue.len().saturating_sub(index + 1);
        let (take, still_missing) = fetch_policy::wave_window_refill(ahead, self.wave_buffer.len());
        if take > 0 {
            queue.extend(self.wave_buffer.drain(..take));
            self.signals.set_queue(queue);
            self.update_prefetch_interest();
        }
        if allow_fetch && still_missing && !self.fetch.is_fetching() {
            self.trigger_fetch();
        }
    }

    /// Stamps rotor-delivered tracks with their fetch time for the TTL prune.
    fn record_wave_fetch<'a, I: IntoIterator<Item = &'a Track>>(&mut self, tracks: I) {
        if !self.in_wave() {
            return;
        }
        let now = std::time::Instant::now();
        for t in tracks {
            self.wave_fetch_times.insert(t.id.clone(), now);
        }
    }

    /// Queue navigation housekeeping: unplayed rotor tracks older than
    /// `WAVE_TRACK_TTL` leave the visible tail and the buffer. Played tracks
    /// (history) and the current track are never dropped.
    fn prune_expired_wave_tracks(&mut self) {
        if !self.in_wave() || self.wave_fetch_times.is_empty() {
            return;
        }
        let now = std::time::Instant::now();
        let played: std::collections::HashSet<&str> = self
            .history
            .entries
            .iter()
            .map(|t| t.id.as_str())
            .collect();
        let current_id = self.signals.queue().get(self.signals.index()).map(|t| t.id.clone());
        let expired_ids: std::collections::HashSet<String> = self
            .wave_fetch_times
            .iter()
            .filter(|(id, ts)| {
                now.duration_since(**ts) > WAVE_TRACK_TTL
                    && !played.contains(id.as_str())
                    && current_id.as_deref() != Some(id.as_str())
            })
            .map(|(id, _)| id.clone())
            .collect();
        if expired_ids.is_empty() {
            return;
        }

        let current_index = self.signals.index();
        let mut queue = self.signals.queue();
        let mut removed = false;
        for i in (current_index + 1..queue.len()).rev() {
            if expired_ids.contains(&queue[i].id) {
                queue.remove(i);
                self.shuffle.record_removed(i);
                removed = true;
            }
        }
        if removed {
            self.signals.set_queue(queue);
            self.signals.bump_revision();
        }
        let buffer_len = self.wave_buffer.len();
        self.wave_buffer
            .retain(|t| !expired_ids.contains(&t.id));
        if removed || self.wave_buffer.len() != buffer_len {
            self.update_prefetch_interest();
        }
    }

    fn wave_append(&mut self, tracks: Vec<Track>) {
        self.record_wave_fetch(tracks.iter());
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
        let (current_id, candidate_ids, next_track) =
            fetch_policy::prefetch_window(&queue, current_index, URL_PREFETCH_WINDOW);

        // Under repeat-single the gapless preheat replays the current track,
        // so that is the session to keep prewarmed.
        let preheat_target = if self.signals.repeat_mode() == RepeatMode::Single {
            queue.get(current_index).cloned()
        } else {
            next_track
        };

        if let Some(next_track) = preheat_target {
            self.stream_manager.prewarm(next_track);
        }

        // Division of labor with prewarm above: a ready decode session
        // already resolved + cached this track's URL, so don't spend a URL
        // batch slot on it. (In-flight prewarm is NOT excluded: if it fails,
        // the URL prefetch is the fallback that keeps the start fast.)
        let needed: Vec<String> = candidate_ids
            .into_iter()
            .filter(|id| !self.stream_manager.has_prewarm_ready(id))
            .collect();

        self.url_prefetcher.update(needed, current_id);
    }

    fn commit_track_to_history(&mut self, track: Track) {
        self.history.push(track);
        self.signals.set_history(self.history.as_vector());
    }

    pub fn set_repeat_mode(&mut self, mode: RepeatMode) {
        self.signals.set_repeat_mode(mode);
    }

    pub fn toggle_repeat_mode(&mut self) -> RepeatMode {
        let new_mode = match self.signals.repeat_mode() {
            RepeatMode::None => RepeatMode::All,
            RepeatMode::All => RepeatMode::Single,
            RepeatMode::Single => RepeatMode::None,
        };
        self.set_repeat_mode(new_mode);
        new_mode
    }

    /// Idempotent shuffle switch: enabling re-rolls the order anchored on the
    /// current track, disabling restores the original order.
    pub fn set_shuffle(&mut self, enabled: bool) {
        if self.signals.is_shuffled() == enabled {
            return;
        }
        if !enabled {
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
        self.update_prefetch_interest();
    }

    /// Returns the resulting shuffle state so the caller can persist it.
    pub fn toggle_shuffle(&mut self) -> bool {
        let target = !self.signals.is_shuffled();
        self.set_shuffle(target);
        target
    }
}

pub fn as_wave_seed(track: &Track) -> String {
    if let Some(album_id) = track.albums.first().and_then(|a| a.id.as_ref()) {
        format!("{}:{}", track.id, album_id)
    } else {
        track.id.clone()
    }
}

/// Normalize a wave seed for the rotor API: a `track:id:title` UI seed
/// becomes the `track:id` the API expects; anything else passes through.
pub(crate) fn clean_wave_seed(seed: &str) -> String {
    if seed.starts_with("track:") {
        seed.split(':').take(2).collect::<Vec<_>>().join(":")
    } else {
        seed.to_string()
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
    async fn repeat_single_replays_on_natural_end() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 1).await;
        q.toggle_repeat_mode(); // None -> All
        q.toggle_repeat_mode(); // All -> Single
        assert_eq!(q.get_next_track().await.unwrap().id, "t1");
    }

    #[tokio::test]
    async fn gapless_peek_returns_successor_without_advancing() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 0).await;
        assert_eq!(q.peek_gapless_next().unwrap().id, "t1");
        // Pure peek: the queue cursor must not have moved.
        assert_eq!(q.get_next_track().await.unwrap().id, "t1");
    }

    #[tokio::test]
    async fn gapless_peek_under_repeat_single_returns_current() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 1).await;
        q.toggle_repeat_mode(); // None -> All
        q.toggle_repeat_mode(); // All -> Single
        // The preheat slot parks a replay of the current track itself.
        assert_eq!(q.peek_gapless_next().unwrap().id, "t1");
        // Pure peek: the queue cursor must not have moved.
        assert_eq!(q.get_next_track().await.unwrap().id, "t1");
    }

    #[tokio::test]
    async fn gapless_peek_wraps_under_repeat_all() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(2), 1).await;
        q.toggle_repeat_mode(); // None -> All
        assert_eq!(q.peek_gapless_next().unwrap().id, "t0");
    }

    #[tokio::test]
    async fn gapless_peek_at_tail_without_repeat_is_none() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(2), 1).await;
        assert!(q.peek_gapless_next().is_none());
    }

    #[tokio::test]
    async fn skip_advances_under_repeat_single() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 1).await;
        q.toggle_repeat_mode(); // None -> All
        q.toggle_repeat_mode(); // All -> Single
        assert_eq!(q.skip_track().await.unwrap().id, "t2");
    }

    #[tokio::test]
    async fn skip_at_tail_under_repeat_single_ends_queue() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(2), 1).await;
        q.toggle_repeat_mode(); // None -> All
        q.toggle_repeat_mode(); // All -> Single
        assert!(q.skip_track().await.is_none());
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
    async fn reorder_moves_track_and_follows_cursor() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(5), 2).await;
        // Move "t0" to the end: [t1 t2 t3 t4 t0], cursor stays on t2 (index 1).
        q.reorder(0, 4);
        assert_eq!(
            q.signals.queue().iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
            vec!["t1", "t2", "t3", "t4", "t0"]
        );
        assert_eq!(q.signals.index(), 1);
        // Move the playing track itself: identity must follow the cursor.
        q.reorder(1, 0);
        assert_eq!(q.signals.index(), 0);
        assert_eq!(q.signals.queue()[0].id, "t2");
        // Revision bumped so the UI observes the same-length reorder.
        assert!(q.signals.inner.queue_revision.get() >= 1);
    }

    #[tokio::test]
    async fn reorder_under_shuffle_keeps_mapping_valid() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(5), 0).await;
        q.toggle_shuffle();
        assert_eq!(q.signals.index(), 0);
        let current_before = q.signals.queue()[0].id.clone();
        let shuffled_before: Vec<String> =
            q.signals.queue().iter().map(|t| t.id.clone()).collect();

        // Reorder within the shuffled order and move the entry back.
        q.reorder(1, 3);
        q.reorder(3, 1);
        let after_roundtrip: Vec<String> =
            q.signals.queue().iter().map(|t| t.id.clone()).collect();

        // Undoing the reorder restores the exact shuffled order.
        assert_eq!(after_roundtrip, shuffled_before);
        // Current track unchanged and still at index 0.
        assert_eq!(q.signals.queue()[0].id, current_before);
        assert_eq!(q.signals.index(), 0);

        // Disable restores the original order and maps the cursor back.
        q.toggle_shuffle();
        assert_eq!(
            q.signals.queue().iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
            vec!["t0", "t1", "t2", "t3", "t4"]
        );
        assert_eq!(q.signals.queue()[q.signals.index()].id, current_before);
    }

    #[tokio::test]
    async fn jump_to_plays_target_and_keeps_queue() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(5), 0).await;
        let track = q.jump_to(3).expect("jump target");
        assert_eq!(track.id, "t3");
        assert_eq!(q.signals.index(), 3);
        // Out-of-range index clamps to the tail.
        let tail = q.jump_to(99).expect("clamped jump");
        assert_eq!(tail.id, "t4");
    }

    #[tokio::test]
    async fn jump_to_under_shuffle_anchors_target_first() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(6), 0).await;
        q.toggle_shuffle();
        // The target is whatever track the shuffled order holds at index 4.
        let target = q.signals.queue()[4].id.clone();
        let track = q.jump_to(4).expect("jump target");
        assert_eq!(track.id, target);
        // The target becomes the first upcoming track.
        assert_eq!(q.signals.index(), 0);
        assert_eq!(q.signals.queue()[0].id, target);
        // Same multiset of tracks.
        let mut ids: Vec<String> = q.signals.queue().iter().map(|t| t.id.clone()).collect();
        ids.sort();
        assert_eq!(ids, vec!["t0", "t1", "t2", "t3", "t4", "t5"]);
    }

    #[tokio::test]
    async fn load_preserves_shuffle_across_context_switch() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(5), 0).await;
        q.toggle_shuffle();
        assert!(q.signals.is_shuffled());

        // A new context keeps the shuffle (persisted flag survives restarts
        // through load_persisted_settings): the new start track anchors first.
        q.load(PlaybackContext::Standalone, standalone(4), 2).await;
        assert!(q.signals.is_shuffled());
        assert_eq!(q.signals.index(), 0);
        assert_eq!(q.signals.queue()[0].id, "t2");

        // Disabling restores the fresh queue's own order, cursor on t2.
        q.toggle_shuffle();
        assert_eq!(
            q.signals
                .queue()
                .iter()
                .map(|t| t.id.clone())
                .collect::<Vec<_>>(),
            vec!["t0", "t1", "t2", "t3"]
        );
        assert_eq!(q.signals.queue()[q.signals.index()].id, "t2");
    }

    #[tokio::test]
    async fn wave_queue_track_pins_after_visible_window() {
        let mut q = manager().await;
        let session: Session = serde_json::from_str(
            r#"{"batchId":"b","descriptionSeed":null,"pumpkin":false,
                "radioSessionId":"r","sequence":[],"terminated":false,
                "wave":null,"unknownSession":null}"#,
        )
        .expect("minimal session parses");
        *q.playback_context.lock() = PlaybackContext::Wave(session);
        q.signals.set_queue(standalone(4)); // current + 3 visible ahead
        q.signals.set_index(0);
        q.wave_buffer = (4..=6).map(|i| test_track(&format!("t{i}"))).collect();

        // "Add to queue" must insert after the visible window (index 4),
        // not at the absolute end and not next to the current track.
        q.queue_track(test_track("pinned"));
        let ids: Vec<String> = q.signals.queue().iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids, vec!["t0", "t1", "t2", "t3", "pinned"]);
        // The rotor tail stays in the buffer behind the pinned track.
        assert_eq!(
            q.wave_buffer.iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
            vec!["t4", "t5", "t6"]
        );

        // "Play next" still inserts at current + 1.
        q.play_next(test_track("next"));
        let ids: Vec<String> = q.signals.queue().iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids, vec!["t0", "next", "t1", "t2", "t3", "pinned"]);
    }

    #[tokio::test]
    async fn non_wave_queue_track_appends_at_end() {
        let mut q = manager().await;
        q.load(PlaybackContext::Standalone, standalone(3), 0).await;
        q.queue_track(test_track("last"));
        let ids: Vec<String> = q.signals.queue().iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids, vec!["t0", "t1", "t2", "last"]);
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

    #[tokio::test]
    async fn wave_history_seeds_are_played_in_order() {
        let mut q = manager().await;
        for i in 0..5 {
            q.history.push(test_track(&format!("t{i}")));
        }
        // Playback order (oldest -> newest), no future/buffered tracks.
        let seeds = q.build_wave_history_seeds();
        assert_eq!(seeds, vec!["t0", "t1", "t2", "t3", "t4"]);
    }

    #[tokio::test]
    async fn wave_history_seeds_cap_at_100_newest() {
        let mut q = manager().await;
        for i in 0..105 {
            q.history.push(test_track(&format!("t{i}")));
        }
        let seeds = q.build_wave_history_seeds();
        assert_eq!(seeds.len(), 100);
        assert_eq!(seeds[0], "t5");
        assert_eq!(seeds[99], "t104");
    }

    #[test]
    fn wave_seeds_keep_the_parts_the_rotor_needs() {
        // `track:<id>:<title>` carries a display title that the rotor rejects.
        assert_eq!(clean_wave_seed("track:123:Some Title"), "track:123");
        // Everything else is passed as-is, including the playlist seed that
        // names both the owner and the kind.
        assert_eq!(
            clean_wave_seed("playlist:1022032131:42"),
            "playlist:1022032131:42"
        );
        assert_eq!(clean_wave_seed("user:onyourwave"), "user:onyourwave");
    }

    #[test]
    fn wave_window_refill_tops_up_visible_ahead_and_requests_more() {
        // Enough buffered: fill the window, no fetch needed.
        assert_eq!(fetch_policy::wave_window_refill(1, 5), (2, false));
        // Partially buffered: take all, still need a page.
        assert_eq!(fetch_policy::wave_window_refill(1, 1), (1, true));
        // Window already full: nothing to do.
        assert_eq!(
            fetch_policy::wave_window_refill(WAVE_VISIBLE_TRACKS, 5),
            (0, false)
        );
        // Empty buffer: nothing to take, fetch needed.
        assert_eq!(fetch_policy::wave_window_refill(0, 0), (0, true));
    }

    #[tokio::test]
    async fn wave_advance_fills_visible_window_from_buffer_without_fetch() {
        let mut q = manager().await;
        let session: Session = serde_json::from_str(
            r#"{"batchId":"b","descriptionSeed":null,"pumpkin":false,
                "radioSessionId":"r","sequence":[],"terminated":false,
                "wave":null,"unknownSession":null}"#,
        )
        .expect("minimal session parses");
        *q.playback_context.lock() = PlaybackContext::Wave(session);
        q.signals.set_queue(standalone(1));
        q.signals.set_index(0);
        q.wave_buffer = (1..=6).map(|i| test_track(&format!("t{i}"))).collect();

        let next = q.get_next_track().await.expect("next from buffer");
        assert_eq!(next.id, "t1");
        // current + WAVE_VISIBLE_TRACKS stay visible after the advance.
        assert_eq!(
            q.signals.queue().len(),
            q.signals.index() + 1 + WAVE_VISIBLE_TRACKS
        );
        // The buffer had enough tracks, so no page request was needed.
        assert!(!q.fetch.is_fetching());
        assert_eq!(q.wave_buffer.len(), 6 - WAVE_VISIBLE_TRACKS - 1);
    }

    #[tokio::test]
    async fn failed_wave_feedbacks_requeue_without_duplicates() {
        use crate::audio::fetcher::{WaveTrackEvent, WaveTrackOutcome};
        use std::time::Duration;

        let mut q = manager().await;
        let event = |id: &str| WaveTrackEvent {
            track_id: id.to_string(),
            batch_id: Some("b1".to_string()),
            total_played: Duration::ZERO,
            track_length: None,
            outcome: WaveTrackOutcome::Finished,
        };
        q.wave_feedbacks.push(event("t1"));
        // t1 already queued -> dropped; t2 prepended for retry.
        q.requeue_failed_wave_feedbacks(vec![event("t1"), event("t2")]);
        let ids: Vec<_> = q
            .wave_feedbacks
            .iter()
            .map(|e| e.track_id.as_str())
            .collect();
        assert_eq!(ids, vec!["t2", "t1"]);
    }

    #[tokio::test]
    async fn wave_batch_attribution_prefers_serving_page() {
        let q = manager().await;
        // Session batch fallback for never-served tracks tested in fetcher;
        // here a serving page overrides it per track.
        q.fetch.remember_wave_batch("page-2", &[test_track("t1")]);
        assert_eq!(
            q.wave_batch_for_track(&test_track("t1")).as_deref(),
            Some("page-2")
        );
    }
}
