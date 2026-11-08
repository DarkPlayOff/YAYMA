use crate::api::models::SimpleTrackDto;
pub use crate::api::models::{PlaybackState, RepeatModeDto};
use crate::app::AppContext;
use crate::audio::commands::AudioMessage;

pub(crate) fn get_playback_state_internal<S: std::hash::BuildHasher>(
    signals: &crate::audio::signals::AudioSignals,
    liked_ids: &std::collections::HashSet<String, S>,
    disliked_ids: &std::collections::HashSet<String, S>,
) -> PlaybackState {
    let current_track = signals.current_track.get();
    PlaybackState {
        is_playing: signals.is_playing.get(),
        is_buffering: signals.is_buffering.get(),
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
        queue_revision: signals.queue_revision.get(),
        current_wave_seeds: signals.current_wave_seeds.get(),
        codec: signals.codec.get(),
        playback_context: signals.playback_context.get(),
        current_track: current_track
            .map(|t| SimpleTrackDto::from_yandex(&t, liked_ids, disliked_ids)),
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
    let _ = ctx.audio.tx.send(AudioMessage::PlayPause).await;
}

pub async fn play(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::Resume).await;
}

pub async fn pause(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::Pause).await;
}

pub async fn play_next(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::Next).await;
}

pub async fn play_prev(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::Prev).await;
}

/// Skips to the previous queue track regardless of the playhead position.
/// The regular `prev` restarts the current track when it has played for a
/// while; gestures that explicitly preview and select the previous cover
/// must always change the track instead.
pub async fn play_previous_track(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::PreviousTrack).await;
}

pub async fn seek(ctx: &AppContext, position_ms: u32) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::Seek(std::time::Duration::from_millis(
            position_ms as u64,
        )))
        .await;
}

pub async fn set_volume(ctx: &AppContext, volume: u8) {
    let _ = ctx.audio.tx.send(AudioMessage::SetVolume(volume)).await;
    let db = ctx.core.db.clone();
    tokio::spawn(async move {
        let mut db = db.lock().await;
        let _ = db.save_setting("volume", &volume).await;
    });
}

/// Sets a non-persistent multiplier for temporary platform audio-focus
/// attenuation. This deliberately leaves the user-visible volume unchanged.
pub async fn set_transient_volume_gain(ctx: &AppContext, gain: u8) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::SetTransientVolumeGain(gain.min(100)))
        .await;
}

/// Inserts the track right after the current one ("play next").
/// No-ops when the track cannot be fetched.
pub async fn queue_add_next(ctx: &AppContext, track_id: String) {
    if let Ok(tracks) = ctx.core.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let _ = ctx.audio.tx.send(AudioMessage::PlayTrackNext(track)).await;
    }
}

/// Appends the track to the end of the queue ("add to queue").
/// In a wave context the insertion lands right after the visible window,
/// ahead of the rotor tail. No-ops when the track cannot be fetched.
pub async fn queue_add_last(ctx: &AppContext, track_id: String) {
    if let Ok(tracks) = ctx.core.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let _ = ctx.audio.tx.send(AudioMessage::QueueTrack(track)).await;
    }
}

/// Removes the queue entry at `index`. Out-of-range indices are ignored.
pub async fn queue_remove_at(ctx: &AppContext, index: u32) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::RemoveFromQueue(index as usize))
        .await;
}

/// Empties the queue without stopping the current playback.
pub async fn queue_clear(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::ClearQueue).await;
}

/// Moves the queue entry at `from` to `to`, keeping the current track
/// playing when it is the one being moved.
pub async fn queue_reorder(ctx: &AppContext, from: u32, to: u32) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::ReorderQueue(from as usize, to as usize))
        .await;
}

/// Jumps to the queue entry at `index` and starts playing it, without
/// resetting the playback context.
pub async fn queue_jump_to(ctx: &AppContext, index: u32) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::PlayQueueIndex(index as usize))
        .await;
}

/// Sets the repeat mode directly (none / all / single) and persists it.
pub async fn set_repeat_mode(ctx: &AppContext, mode: RepeatModeDto) {
    let mode = match mode {
        RepeatModeDto::None => crate::audio::enums::RepeatMode::None,
        RepeatModeDto::All => crate::audio::enums::RepeatMode::All,
        RepeatModeDto::Single => crate::audio::enums::RepeatMode::Single,
    };
    let _ = ctx.audio.tx.send(AudioMessage::SetRepeatMode(mode)).await;
}

/// Enables or disables shuffle and persists the choice.
pub async fn set_shuffle(ctx: &AppContext, enabled: bool) {
    let _ = ctx.audio.tx.send(AudioMessage::SetShuffle(enabled)).await;
}

pub async fn toggle_shuffle(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::ToggleShuffle).await;
}

pub async fn toggle_repeat_mode(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::ToggleRepeatMode).await;
}

pub async fn stop(ctx: &AppContext) {
    let _ = ctx.audio.tx.send(AudioMessage::Stop).await;
}

pub async fn get_queue(ctx: &AppContext) -> Vec<SimpleTrackDto> {
    let (liked_ids, disliked_ids) = ctx.audio.state.read().await.liked.snapshot();
    ctx.audio.signals.queue.with(|q| {
        q.iter()
            .map(|t| SimpleTrackDto::from_yandex(t, &liked_ids, &disliked_ids))
            .collect()
    })
}

/// Returns up to `len` queue entries starting at the absolute position
/// `offset`, so large queues do not have to be copied whole. Out-of-range
/// parts are silently clamped.
pub async fn queue_window(ctx: &AppContext, offset: u32, len: u32) -> Vec<SimpleTrackDto> {
    let (liked_ids, disliked_ids) = ctx.audio.state.read().await.liked.snapshot();
    ctx.audio.signals.queue.with(|q| {
        let start = (offset as usize).min(q.len());
        q.iter()
            .skip(start)
            .take(len as usize)
            .map(|t| SimpleTrackDto::from_yandex(t, &liked_ids, &disliked_ids))
            .collect()
    })
}

/// A page of the server-side history shown on the "История" tab. The endpoint
/// returns its whole window at once, so paging happens on our side: the view
/// asks for 50 at a time while scrolling.
pub async fn get_history(ctx: &AppContext, offset: usize, limit: usize) -> Vec<SimpleTrackDto> {
    let (liked_ids, disliked_ids) = ctx.audio.state.read().await.liked.snapshot();
    match ctx.core.api.fetch_music_history(offset, limit).await {
        Ok(tracks) => tracks
            .iter()
            .map(|t| SimpleTrackDto::from_yandex(t, &liked_ids, &disliked_ids))
            .collect(),
        Err(e) => {
            tracing::error!(error = ?e, "fetch_history_failed");
            Vec::new()
        }
    }
}

pub async fn play_track(ctx: &AppContext, track_id: String) {
    if let Ok(tracks) = ctx.core.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let _ = ctx.audio.tx.send(AudioMessage::PlayTrack(track)).await;
    }
}

pub async fn restore_and_play(
    ctx: &AppContext,
    track_id: String,
    position_ms: u32,
    is_playing: bool,
) {
    if let Ok(tracks) = ctx.core.api.fetch_tracks(vec![track_id]).await
        && let Some(track) = tracks.into_iter().next()
    {
        let pos = std::time::Duration::from_millis(position_ms as u64);
        let _ = ctx
            .audio
            .tx
            .send(AudioMessage::RestoreTrack(track, pos, is_playing))
            .await;
    }
}

pub async fn play_playlist(ctx: &AppContext, _uid: String, kind: u32) {
    let _ = ctx.audio.tx.send(AudioMessage::PlayPlaylist(kind)).await;
}

pub async fn play_album(ctx: &AppContext, album_id: u32) {
    let _ = ctx.audio.tx.send(AudioMessage::PlayAlbum(album_id)).await;
}

pub async fn play_album_track(ctx: &AppContext, album_id: u32, track_id: String) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::PlayAlbumTrack(album_id, track_id))
        .await;
}

pub async fn play_playlist_track(ctx: &AppContext, _uid: String, kind: u32, track_id: String) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::PlayPlaylistTrack(kind, track_id))
        .await;
}

pub async fn play_liked_track(ctx: &AppContext, track_id: String) {
    let _ = ctx
        .audio
        .tx
        .send(AudioMessage::PlayLikedTrack(track_id))
        .await;
}

pub async fn start_wave(ctx: &AppContext, seeds: Vec<String>) {
    let _ = ctx.audio.tx.send(AudioMessage::StartWave(seeds)).await;
}

/// Seed used when no specific wave station is selected.
pub const DEFAULT_WAVE_SEED: &str = "user:onyourwave";

/// Station category: the part of a seed before the first ':'.
/// Seeds without ':' form a category of their own.
fn wave_seed_category(seed: &str) -> &str {
    match seed.find(':') {
        Some(idx) => &seed[..idx],
        None => seed,
    }
}

/// Toggle a wave station, owning the full seed policy that used to live in
/// Dart (`WaveController.toggleStation`):
/// - if `seed` is active, remove it;
/// - otherwise drop the default seed plus every seed of the same category,
///   then add `seed`;
/// - if nothing is left, fall back to the default seed.
///
/// Afterwards a wave is (re)started with the resulting seeds.
pub async fn toggle_wave_station(ctx: &AppContext, seed: String) {
    let mut seeds = ctx.audio.signals.current_wave_seeds.get();
    if seeds.contains(&seed) {
        seeds.retain(|s| *s != seed);
    } else {
        let prefix = format!("{}:", wave_seed_category(&seed));
        seeds.retain(|s| *s != DEFAULT_WAVE_SEED && !s.starts_with(&prefix));
        seeds.push(seed);
    }
    if seeds.is_empty() {
        seeds.push(DEFAULT_WAVE_SEED.to_string());
    }
    let _ = ctx.audio.tx.send(AudioMessage::StartWave(seeds)).await;
}

/// (Re)start "My wave": keep the current seeds, defaulting to the
/// `user:onyourwave` seed when nothing is selected.
pub async fn start_my_wave(ctx: &AppContext) {
    let seeds = ctx.audio.signals.current_wave_seeds.get();
    let seeds = if seeds.is_empty() {
        vec![DEFAULT_WAVE_SEED.to_string()]
    } else {
        seeds
    };
    let _ = ctx.audio.tx.send(AudioMessage::StartWave(seeds)).await;
}
