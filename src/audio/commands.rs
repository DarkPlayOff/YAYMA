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
    ToggleMute,

    // Queue & Context
    PlayTrack(Track),
    PlayTrackPaused(Track, Duration),
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

    // Internal/Other
    ReloadCurrentTrack,
    TrackEnded,
}
