use crate::api::models::SimpleTrackDto;
pub use crate::api::models::{PlaybackState, RepeatModeDto};
use crate::app::AppContext;
use crate::audio::commands::AudioMessage;

#[flutter_rust_bridge::frb(ignore)]
pub fn get_playback_state_internal<S: std::hash::BuildHasher>(
    signals: &crate::audio::signals::AudioSignals,
    liked_ids: &std::collections::HashSet<String, S>,
    disliked_ids: &std::collections::HashSet<String, S>,
) -> PlaybackState {
    let current_track = signals.current_track.get();
    PlaybackState {
        is_playing: signals.is_playing.get(),
        volume: signals.volume.get(),
        is_muted: signals.is_muted.get(),
        repeat_mode: match signals.repeat_mode.get() {
            crate::audio::enums::RepeatMode::None => RepeatModeDto::None,
            crate::audio::enums::RepeatMode::All => RepeatModeDto::All,
            crate::audio::enums::RepeatMode::Single => RepeatModeDto::Single,
        },
        is_shuffled: signals.is_shuffled.get(),
        queue_count: signals.queue_length.get() as u32,
        queue_index: signals.queue_index.get() as u32,
        current_wave_seeds: signals.current_wave_seeds.get(),
        codec: signals.codec.get(),
        current_track: current_track
            .map(|t| SimpleTrackDto::from_yandex(t, liked_ids, disliked_ids)),
    }
}

pub fn get_playback_state(
    signals: &crate::audio::signals::AudioSignals,
    liked_ids: &std::collections::HashSet<String>,
    disliked_ids: &std::collections::HashSet<String>,
) -> PlaybackState {
    get_playback_state_internal(signals, liked_ids, disliked_ids)
}

pub async fn toggle_play_pause(ctx: &AppContext) {
    let _ = ctx.audio_tx.send(AudioMessage::PlayPause).await;
}

pub async fn play_next(ctx: &AppContext) {
    let _ = ctx.audio_tx.send(AudioMessage::Next).await;
}

pub async fn play_prev(ctx: &AppContext) {
    let _ = ctx.audio_tx.send(AudioMessage::Prev).await;
}

pub async fn seek(ctx: &AppContext, position_ms: u32) {
    let _ = ctx
        .audio_tx
        .send(AudioMessage::Seek(std::time::Duration::from_millis(
            position_ms as u64,
        )))
        .await;
}

pub async fn set_volume(ctx: &AppContext, volume: u8) {
    let _ = ctx.audio_tx.send(AudioMessage::SetVolume(volume)).await;
    let db = ctx.db.clone();
    tokio::task::spawn_blocking(move || {
        let db = db.lock();
        let _ = db.save_volume(volume);
    });
}

pub async fn toggle_shuffle(ctx: &AppContext) {
    let _ = ctx.audio_tx.send(AudioMessage::ToggleShuffle).await;
}

pub async fn toggle_repeat_mode(ctx: &AppContext) {
    let _ = ctx.audio_tx.send(AudioMessage::ToggleRepeatMode).await;
}

pub async fn get_queue(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    let (liked_ids, disliked_ids) = ctx.state.read().await.liked.snapshot();
    ctx.signals.queue.with(|q| {
        q.iter()
            .map(|t| SimpleTrackDto::from_yandex_ref(t, &liked_ids, &disliked_ids))
            .collect()
    })
}

pub async fn get_history(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    let (liked_ids, disliked_ids) = ctx.state.read().await.liked.snapshot();
    ctx.signals.history.with(|h| {
        h.iter()
            .map(|t| SimpleTrackDto::from_yandex_ref(t, &liked_ids, &disliked_ids))
            .collect()
    })
}

pub async fn play_track(ctx: &AppContext, track_id: String) {
    if let Ok(tracks) = ctx.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let _ = ctx.audio_tx.send(AudioMessage::PlayTrack(track)).await;
    }
}

pub async fn restore_and_play(
    ctx: &AppContext,
    track_id: String,
    position_ms: u32,
    is_playing: bool,
) {
    if let Ok(tracks) = ctx.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let pos = std::time::Duration::from_millis(position_ms as u64);
        let _ = ctx
            .audio_tx
            .send(AudioMessage::PlayTrackPaused(track, pos))
            .await;
        if is_playing {
            let _ = ctx.audio_tx.send(AudioMessage::Resume).await;
        }
    }
}

pub async fn play_playlist(ctx: &AppContext, _uid: String, kind: u32) {
    let _ = ctx.audio_tx.send(AudioMessage::PlayPlaylist(kind)).await;
}

pub async fn play_album(ctx: &AppContext, album_id: u32) {
    let _ = ctx.audio_tx.send(AudioMessage::PlayAlbum(album_id)).await;
}

pub async fn play_album_track(ctx: &AppContext, album_id: u32, track_id: String) {
    let _ = ctx
        .audio_tx
        .send(AudioMessage::PlayAlbumTrack(album_id, track_id))
        .await;
}

pub async fn play_playlist_track(ctx: &AppContext, _uid: String, kind: u32, track_id: String) {
    let _ = ctx
        .audio_tx
        .send(AudioMessage::PlayPlaylistTrack(kind, track_id))
        .await;
}

pub async fn play_liked_track(ctx: &AppContext, track_id: String) {
    let _ = ctx
        .audio_tx
        .send(AudioMessage::PlayLikedTrack(track_id))
        .await;
}

pub async fn start_wave(ctx: &AppContext, seeds: Vec<String>) {
    let _ = ctx.audio_tx.send(AudioMessage::StartWave(seeds)).await;
}
