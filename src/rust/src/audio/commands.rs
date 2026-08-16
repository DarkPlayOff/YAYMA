use crate::audio::queue::PlaybackContext;
use im::Vector;
use std::time::Duration;
use yandex_music::model::track::Track;

#[derive(Debug, Clone)]
pub enum AudioMessage {
    // Basic playback
    PlayPause,
    Pause,
    Resume,
    Stop,
    Next,
    Prev,
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
    RecreateStream,
}
