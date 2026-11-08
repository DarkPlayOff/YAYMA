//! Listening reports to `POST /plays`: they write the server-side playback
//! history (the "История" page and the recommendations input).

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use rand::{Rng, RngExt};
use serde_json::{Value, json};
use yandex_music::model::track::Track;

use crate::audio::queue::PlaybackContext;
use crate::http::{ApiService, SessionExt};

/// Progress report interval while playing (the desktop client's default 30 s).
const PERIODIC_SEND_INTERVAL: f64 = 30.0;
/// Values this close to the track length count as the full length.
const TRACK_END_SNAP_SECONDS: f64 = 0.5;

/// The active listen's context, mapped from [`PlaybackContext`]. The server
/// drops any report without `from`.
#[derive(Clone, Debug)]
pub struct PlayContext {
    pub context: String,
    /// `None` where the server groups without an id (`other`).
    pub context_item: Option<String>,
    pub from: String,
    pub playlist_id: Option<String>,
    pub radio_session_id: Option<String>,
    pub batch_id: Option<String>,
}

impl PlayContext {
    pub fn from_playback(ctx: &PlaybackContext) -> Self {
        match ctx {
            PlaybackContext::Playlist(playlist) => {
                // A bare `kind` is accepted (200 ok) but silently dropped from
                // the history; only the resolvable `"<uid>:<kind>"` is stored.
                let id = format!("{}:{}", playlist.owner.uid, playlist.kind);
                Self {
                    context: "playlist".into(),
                    context_item: Some(id.clone()),
                    from: format!("default-playlist-{}", playlist.kind),
                    playlist_id: Some(id),
                    radio_session_id: None,
                    batch_id: None,
                }
            }
            PlaybackContext::Artist(artist) => Self {
                context: "artist".into(),
                context_item: artist.id.clone(),
                from: "artist-page".into(),
                playlist_id: None,
                radio_session_id: None,
                batch_id: None,
            },
            PlaybackContext::Album(album) => Self {
                context: "album".into(),
                context_item: album.id.map(|id| id.to_string()),
                from: "album-page".into(),
                playlist_id: None,
                radio_session_id: None,
                batch_id: None,
            },
            // A lone track is recorded only as `other` with a null
            // `contextItem`; `track`/`various` are silently dropped.
            PlaybackContext::Track(_) => Self {
                context: "other".into(),
                context_item: None,
                from: "track-page".into(),
                playlist_id: None,
                radio_session_id: None,
                batch_id: None,
            },
            PlaybackContext::Wave(session) => {
                // History groups radio by the wave seeds (`"user:onyourwave"`,
                // `"track:<id>"`), not by the radio-session id.
                let seeds = session
                    .wave
                    .as_ref()
                    .map(|w| w.seeds.join(","))
                    .unwrap_or_default();
                Self {
                    context: "radio".into(),
                    context_item: Some(if seeds.is_empty() {
                        session.station_id().to_string()
                    } else {
                        seeds
                    }),
                    from: session.source_id().to_string(),
                    playlist_id: None,
                    radio_session_id: session.radio_session_id.clone(),
                    batch_id: Some(session.batch_id.clone()),
                }
            }
            PlaybackContext::Standalone => Self {
                context: "other".into(),
                context_item: None,
                from: "desktop".into(),
                playlist_id: None,
                radio_session_id: None,
                batch_id: None,
            },
        }
    }
}

/// Why a listen ended; maps to the desktop client's `changeReason` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    Finished,
    Skip,
    /// Skip driven by a dislike: reported as `dislike`, not `skip`.
    Dislike,
    BackSkip,
    OtherTrack,
}

impl EndReason {
    fn change_reason(self) -> &'static str {
        match self {
            EndReason::Finished => "finish",
            EndReason::Skip => "skip",
            EndReason::Dislike => "dislike",
            EndReason::BackSkip => "back_skip",
            EndReason::OtherTrack => "other_track",
        }
    }
}

/// Where reports go. The default sink is a bounded queue drained by one task,
/// so order is kept and only one request is in flight; a full queue (server
/// stalled) drops the newest report instead of piling up.
type PlaySink = Box<dyn Fn(Value) + Send + Sync>;

fn default_sink(api: Arc<ApiService>) -> PlaySink {
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Value>(64);
    tokio::spawn(async move {
        while let Some(report) = rx.recv().await {
            // Log what went out, so an "empty history" report is triageable.
            let reason = report["changeReason"]
                .as_str()
                .unwrap_or_else(|| {
                    if report["pause"].as_bool().unwrap_or(false) {
                        "pause"
                    } else {
                        "start"
                    }
                })
                .to_string();
            let summary = (
                report["trackId"].as_str().unwrap_or("-").to_string(),
                report["context"].as_str().unwrap_or("-").to_string(),
                report["from"].as_str().unwrap_or("-").to_string(),
                reason,
                report["totalPlayedSeconds"].as_f64().unwrap_or(0.0),
            );
            match api.send_plays(vec![report]).await {
                Ok(()) => {}
                Err(e) => tracing::warn!(
                    track_id = summary.0,
                    context = summary.1,
                    from = summary.2,
                    error = %e,
                    "play_report_failed"
                ),
            }
        }
    });
    Box::new(move |report: Value| {
        if tx.try_send(report).is_err() {
            tracing::warn!("play_report_dropped_queue_full");
        }
    })
}

pub struct PlayReporter {
    send: PlaySink,
    play_id: String,
    ctx: Option<PlayContext>,
    track_id: Option<String>,
    album_id: Option<String>,
    track_len: Option<f64>,
    start_position: f64,
    start_timestamp: String,
    add_tracks_to_player_time: String,
    is_repeated: bool,
    /// Anchor of the current uninterrupted playing stretch.
    playing_since: Option<Instant>,
    played_seconds: f64,
    /// Played-seconds threshold for the next progress report.
    next_periodic_at: f64,
    seek_pending: bool,
    last_track_id: Option<String>,
    /// Set when loaded paused: the `start` report waits for the first resume.
    pending_start: bool,
    /// Duplicate Pause messages must not produce duplicate reports.
    paused: bool,
}

impl PlayReporter {
    pub fn new(api: Arc<ApiService>) -> Self {
        Self::with_sender(default_sink(api))
    }

    /// Test injection point: `send` gets one report per call, synchronously.
    pub fn with_sender(send: PlaySink) -> Self {
        Self {
            send,
            play_id: new_play_id(),
            ctx: None,
            track_id: None,
            album_id: None,
            track_len: None,
            start_position: 0.0,
            start_timestamp: iso_now(),
            add_tracks_to_player_time: new_add_tracks_time(),
            is_repeated: false,
            playing_since: None,
            played_seconds: 0.0,
            next_periodic_at: PERIODIC_SEND_INTERVAL,
            seek_pending: false,
            last_track_id: None,
            pending_start: false,
            paused: false,
        }
    }

    /// A track began playing (or was loaded paused). An active previous listen
    /// is implicitly closed as `other_track`, like the desktop client does.
    pub fn track_start(
        &mut self,
        track: &Track,
        ctx: PlayContext,
        position: Duration,
        track_len: Duration,
        paused: bool,
    ) {
        // No end event exists at this switch; the played time is the best
        // position estimate, so close as `other_track`.
        self.finalize_current(EndReason::OtherTrack);

        let track_id = track.id.clone();
        let repeated = self.last_track_id.as_deref() == Some(track_id.as_str());
        self.last_track_id = Some(track_id.clone());

        self.play_id = new_play_id();
        self.ctx = Some(ctx);
        self.track_id = Some(track_id);
        self.album_id = track
            .albums
            .first()
            .and_then(|a| a.id)
            .map(|id| id.to_string());
        self.track_len = Some(track_len.as_secs_f64());
        self.start_position = position.as_secs_f64();
        self.start_timestamp = iso_now();
        self.add_tracks_to_player_time = new_add_tracks_time();
        self.is_repeated = repeated;
        self.played_seconds = 0.0;
        self.next_periodic_at = PERIODIC_SEND_INTERVAL;
        self.seek_pending = false;
        self.playing_since = (!paused).then(Instant::now);
        self.pending_start = paused;
        self.paused = paused;

        if !paused {
            self.send_report(0.0, false, None);
        }
    }

    pub fn pause(&mut self, position: Duration) {
        if self.paused {
            return;
        }
        self.paused = true;
        self.accumulate();
        self.playing_since = None;
        if self.pending_start {
            // No `start` was sent yet; a `pause` for an unknown playId is noise.
            return;
        }
        self.send_report(position.as_secs_f64(), true, None);
    }

    /// Playback continues: flushes the deferred `start`, or re-arms the anchor
    /// after a silent stall (Resume without a Pause).
    pub fn resume(&mut self) {
        if self.paused {
            self.paused = false;
            if self.pending_start {
                self.pending_start = false;
                self.send_report(self.start_position, false, None);
            }
        } else if self.playing_since.is_some() {
            return;
        }
        self.playing_since = Some(Instant::now());
    }

    pub fn seek(&mut self) {
        self.seek_pending = true;
    }

    /// Periodic driver (~5 s): sends progress reports and is the only
    /// wall-clock accountant, so silent stalls don't count as played time.
    pub fn tick(&mut self, playing: bool, position: Duration) {
        if self.ctx.is_none() || self.pending_start || self.paused {
            return;
        }
        if playing {
            self.accumulate();
            self.playing_since = Some(Instant::now());
            if self.played_seconds >= self.next_periodic_at {
                self.next_periodic_at += PERIODIC_SEND_INTERVAL;
                self.send_report(position.as_secs_f64(), false, Some("in_progress"));
            }
        } else if self.playing_since.is_some() {
            // Charge at most one tick more, not the whole silent stretch.
            self.accumulate();
        }
    }

    /// The listen ended: sends the final report with `reason` and `position`.
    pub fn track_end(&mut self, reason: EndReason, position: Duration) {
        if self.track_id.is_none() {
            return;
        }
        self.accumulate();
        self.playing_since = None;
        if !self.pending_start {
            self.send_report(position.as_secs_f64(), false, Some(reason.change_reason()));
        }
        self.reset_session();
    }

    /// Closes the active listen when no end position is known (track/context
    /// switch): `start_position + played_seconds` stands in for it.
    fn finalize_current(&mut self, reason: EndReason) {
        if self.track_id.is_none() {
            return;
        }
        self.accumulate();
        self.playing_since = None;
        if !self.pending_start {
            // The field is absolute, so a listen that started mid-track must
            // be offset by the start position.
            self.send_report(
                self.start_position + self.played_seconds,
                false,
                Some(reason.change_reason()),
            );
        }
        self.reset_session();
    }

    fn reset_session(&mut self) {
        self.ctx = None;
        self.track_id = None;
        self.album_id = None;
        self.track_len = None;
        self.played_seconds = 0.0;
        self.next_periodic_at = PERIODIC_SEND_INTERVAL;
        self.seek_pending = false;
        self.pending_start = false;
        self.paused = false;
    }

    /// Adds the current playing stretch to `played_seconds`, keeping the anchor.
    fn accumulate(&mut self) {
        if let Some(since) = self.playing_since.take() {
            self.played_seconds += since.elapsed().as_secs_f64();
        }
    }

    /// Builds and dispatches one report. Snaps `end_position` to the track
    /// length when close; radio always reports played time as the position.
    fn send_report(&mut self, end_position: f64, pause: bool, change_reason: Option<&str>) {
        let Some(ctx) = self.ctx.clone() else {
            return;
        };
        let Some(track_id) = self.track_id.clone() else {
            return;
        };

        let mut played = self.played_seconds;
        let mut end_position = if ctx.context == "radio" {
            played
        } else {
            end_position.max(0.0)
        };
        if let Some(len) = self.track_len
            && len > 0.0
        {
            if (len - played).abs() < TRACK_END_SNAP_SECONDS {
                played = len;
            }
            if (len - end_position).abs() < TRACK_END_SNAP_SECONDS {
                end_position = len;
            }
        }

        let mut report = json!({
            "playId": self.play_id,
            "from": ctx.from,
            "context": ctx.context,
            "contextItem": ctx.context_item,
            "trackId": track_id,
            "albumId": self.album_id.clone(),
            "playlistId": ctx.playlist_id,
            "timestamp": iso_now(),
            "startTimestamp": self.start_timestamp,
            "totalPlayedSeconds": played,
            "endPositionSeconds": end_position,
            "trackLengthSeconds": self.track_len,
            "startPositionSeconds": self.start_position,
            "seek": self.seek_pending,
            "pause": pause,
            "isRepeated": self.is_repeated,
            "addTracksToPlayerTime": self.add_tracks_to_player_time,
        });
        if let Some(reason) = change_reason {
            report["changeReason"] = json!(reason);
        }
        if let Some(session_id) = ctx.radio_session_id {
            report["radioSessionId"] = json!(session_id);
        }
        if let Some(batch) = ctx.batch_id {
            report["batchId"] = json!(batch);
        }
        self.seek_pending = false;

        (self.send)(report);
    }
}

fn iso_now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// Desktop client's `addTracksToPlayerTime`: random digits + unix seconds.
fn new_add_tracks_time() -> String {
    let digits = rand::rng().random_range(100_000_000_000_u64..1_000_000_000_000);
    format!("{}-{}", digits, Utc::now().timestamp())
}

/// Random UUID v4 for `playId`.
fn new_play_id() -> String {
    let mut b = [0u8; 16];
    rand::rng().fill_bytes(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex = |bytes: &[u8]| -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() };
    format!(
        "{}-{}-{}-{}-{}",
        hex(&b[0..4]),
        hex(&b[4..6]),
        hex(&b[6..8]),
        hex(&b[8..10]),
        hex(&b[10..16])
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Reporter with a synchronous recording sink, in dispatch order.
    fn recorded() -> (PlayReporter, Arc<Mutex<Vec<Value>>>) {
        let log: Arc<Mutex<Vec<Value>>> = Arc::default();
        let sink_log = log.clone();
        let reporter = PlayReporter::with_sender(Box::new(move |play| {
            sink_log.lock().unwrap().push(play);
        }));
        (reporter, log)
    }

    fn track(id: &str, len_ms: u64) -> Track {
        serde_json::from_value(json!({ "id": id, "realId": id, "durationMs": len_ms })).unwrap()
    }

    fn ctx() -> PlayContext {
        PlayContext {
            context: "playlist".into(),
            context_item: Some("1:3".into()),
            from: "default-playlist-3".into(),
            playlist_id: Some("1:3".into()),
            radio_session_id: None,
            batch_id: None,
        }
    }

    #[test]
    fn silent_pause_stops_played_time() {
        let (mut reporter, log) = recorded();
        reporter.track_start(
            &track("a", 300_000),
            ctx(),
            Duration::ZERO,
            Duration::from_secs(300),
            false,
        );

        let t0 = Instant::now();
        // play → silent pause (only is_playing=false) → play → end.
        std::thread::sleep(Duration::from_millis(40));
        reporter.tick(true, Duration::from_millis(40));
        std::thread::sleep(Duration::from_millis(40));
        reporter.tick(false, Duration::ZERO);
        std::thread::sleep(Duration::from_millis(40));
        reporter.tick(true, Duration::from_millis(120));
        std::thread::sleep(Duration::from_millis(40));
        reporter.track_end(EndReason::Finished, Duration::from_millis(120));

        let total = t0.elapsed().as_secs_f64();
        let end = log.lock().unwrap().last().cloned().unwrap();
        let played = end["totalPlayedSeconds"].as_f64().unwrap();
        // Both playing stretches count, the silent one must not (tolerances
        // absorb sleep overshoot).
        assert!(played >= total * 0.3, "undercounted: {played} of {total}");
        assert!(
            played <= total * 0.85,
            "silent pause counted as played: {played} of {total}"
        );
    }

    #[test]
    fn pending_start_suppresses_reports_until_resume() {
        let (mut reporter, log) = recorded();
        reporter.track_start(
            &track("a", 100_000),
            ctx(),
            Duration::from_secs(30),
            Duration::from_secs(100),
            true,
        );
        // Pausing a track that never sent `start` must not report.
        reporter.pause(Duration::from_secs(30));
        assert!(log.lock().unwrap().is_empty());

        reporter.resume();
        reporter.track_end(EndReason::Skip, Duration::from_secs(45));

        let reports = log.lock().unwrap();
        assert_eq!(reports.len(), 2, "only start + end expected");
        assert_eq!(reports[0]["startPositionSeconds"], json!(30.0));
        assert_eq!(reports[1]["changeReason"], json!("skip"));
        assert_eq!(reports[0]["playId"], reports[1]["playId"]);
    }

    #[test]
    fn repeated_pause_reports_once_and_ignores_stale_ticks() {
        let (mut reporter, log) = recorded();
        reporter.track_start(
            &track("a", 100_000),
            ctx(),
            Duration::ZERO,
            Duration::from_secs(100),
            false,
        );
        reporter.pause(Duration::from_secs(10));
        std::thread::sleep(Duration::from_millis(10));
        reporter.pause(Duration::from_secs(10)); // duplicate Pause message
        // A stale `is_playing` tick while paused must not count time.
        reporter.tick(true, Duration::from_secs(10));
        reporter.track_end(EndReason::Skip, Duration::from_secs(10));

        let reports = log.lock().unwrap();
        let pauses = reports.iter().filter(|r| r["pause"] == json!(true)).count();
        assert_eq!(pauses, 1, "duplicate pause report sent");
        assert_eq!(reports.len(), 3, "start + pause + skip expected");
    }

    #[test]
    fn end_position_snaps_to_track_length() {
        let (mut reporter, log) = recorded();
        reporter.track_start(
            &track("a", 100_000),
            ctx(),
            Duration::ZERO,
            Duration::from_secs(100),
            false,
        );
        // Natural end: the position signal stops 100 ms short of the length.
        reporter.track_end(EndReason::Finished, Duration::from_millis(99_900));

        let end = log.lock().unwrap().last().cloned().unwrap();
        assert_eq!(end["endPositionSeconds"], json!(100.0));
    }

    #[test]
    fn track_switch_finalizes_previous_listen_as_other_track() {
        let (mut reporter, log) = recorded();
        reporter.track_start(
            &track("a", 100_000),
            ctx(),
            Duration::ZERO,
            Duration::from_secs(100),
            false,
        );
        reporter.track_start(
            &track("b", 100_000),
            ctx(),
            Duration::ZERO,
            Duration::from_secs(100),
            false,
        );

        let reports = log.lock().unwrap();
        // start(a) → other_track end(a) → start(b)
        assert_eq!(reports.len(), 3);
        assert_eq!(reports[0]["trackId"], json!("a"));
        assert_eq!(reports[1]["changeReason"], json!("other_track"));
        assert_eq!(reports[1]["trackId"], json!("a"));
        assert_eq!(reports[2]["trackId"], json!("b"));
        assert_ne!(reports[1]["playId"], reports[2]["playId"]);
    }

    #[test]
    fn play_id_is_uuid_v4() {
        for _ in 0..16 {
            let id = new_play_id();
            assert_eq!(id.len(), 36);
            let parts: Vec<&str> = id.split('-').collect();
            assert_eq!(
                parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
                [8, 4, 4, 4, 12]
            );
            assert!(id.chars().all(|c| c == '-' || c.is_ascii_hexdigit()));
            // version 4 nibble and the 10xx variant bits
            assert!(parts[2].starts_with('4'));
            assert!(matches!(
                parts[3].chars().next(),
                Some('8' | '9' | 'a' | 'b')
            ));
        }
    }

    #[test]
    fn add_tracks_time_matches_desktop_shape() {
        let t = new_add_tracks_time();
        // "<random digits>-<unix seconds>"
        let (digits, seconds) = t.split_once('-').expect("dash separator");
        assert_eq!(digits.len(), 12);
        assert!(digits.chars().all(|c| c.is_ascii_digit()));
        assert!(seconds.parse::<i64>().is_ok());
    }

    #[test]
    fn end_reasons_map_to_desktop_change_reasons() {
        assert_eq!(EndReason::Finished.change_reason(), "finish");
        assert_eq!(EndReason::Skip.change_reason(), "skip");
        assert_eq!(EndReason::Dislike.change_reason(), "dislike");
        assert_eq!(EndReason::BackSkip.change_reason(), "back_skip");
        assert_eq!(EndReason::OtherTrack.change_reason(), "other_track");
    }
}
