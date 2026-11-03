use crate::audio::enums::RepeatMode;
use crate::audio::queue::PlaybackContext;
use im::Vector;
use std::time::Duration;
use yandex_music::model::track::Track;

#[derive(Debug, Clone)]
pub enum AudioMessage {
    ContextFetched {
        generation: u64,
        result: Result<(PlaybackContext, Vector<Track>, usize), String>,
    },
    // Basic playback
    PlayPause,
    Pause,
    Resume,
    Stop,
    Next,
    Prev,
    /// Unconditional previous-track skip: unlike `Prev`, it does not restart
    /// the current track when the playhead is past the restart threshold.
    PreviousTrack,
    Seek(Duration),
    SetVolume(u8),
    /// Applies a transient gain on top of the user volume without changing
    /// the volume signal or its persisted setting (e.g. Android ducking).
    SetTransientVolumeGain(u8),
    ToggleMute,

    // Queue & Context
    PlayTrack(Track),
    /// Restores a persisted session: the track, where it left off, and whether it
    /// was playing. The play state has to ride along with the track — resuming with
    /// a separate `Resume` message races the spawned playback task, which applies
    /// its own start-paused state afterwards and would pause it right back.
    RestoreTrack(Track, Duration, bool),
    LoadContext(PlaybackContext, Vector<Track>, usize),
    LoadTracks(Vec<Track>),
    QueueTrack(Track),
    PlayTrackNext(Track),
    RemoveFromQueue(usize),
    ClearQueue,
    /// Moves the queue entry at `from` to `to`, keeping the current track
    /// playing when it is the one being moved.
    ReorderQueue(usize, usize),
    /// Jumps to the queue entry at `index` and plays it; under shuffle the
    /// order is re-rolled anchored on the target track.
    PlayQueueIndex(usize),
    SetRepeatMode(RepeatMode),
    SetShuffle(bool),
    ToggleShuffle,
    ToggleRepeatMode,

    // Yandex specific (will be handled by YandexProvider)
    PlayPlaylist(u32),
    PlayAlbum(u32),
    PlayAlbumTrack(u32, String),
    PlayPlaylistTrack(u32, String),
    PlayLikedTrack(String),
    StartWave(Vec<String>),
    SyncLiked,
    WaveLike(String),
    WaveUnlike(String),
    WaveDislike(String),
    WaveUndislike(String),

    // Device
    SetAudioDevice(Option<String>),

    // Internal/Other
    ReloadCurrentTrack,
    TrackEnded,
    /// Monitor request (throttled): with the current track nearing its end,
    /// park the prewarmed next session on the second engine player so the
    /// boundary swap is seamless.
    PreheatNext,
    /// Fired by the boundary watch thread within milliseconds of the current
    /// source's last sample. Handlers filter stale firings (player stopped by
    /// skip/seek) via the preheat state and the engine emptiness.
    BoundaryCrossed,
    /// Monitor request: the configured crossfade window has been reached with
    /// a preheated next session parked — start the overlap transition.
    BeginCrossfade,
    RecreateStream,
}
