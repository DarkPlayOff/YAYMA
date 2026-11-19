use crate::audio::util::{construct_sink, setup_device_config};
use rodio::{MixerDeviceSink, Player, Source};
use std::num::NonZero;
use std::sync::Arc;

/// Player slots and fader state of the engine. Device-free on purpose: the
/// mixer-facing plumbing (`MixerDeviceSink`, resampling) stays in
/// `EngineState`, while the slot juggling is unit-testable against a
/// standalone rodio mixer — no audio device needed.
struct EnginePlayers {
    sink: Arc<Player>,
    /// Parked (paused) player holding the preheated next track. Both players
    /// share the device mixer, so promoting the preheat is a pointer swap —
    /// the audio pipeline (device stream, mixer, resampler setup) never tears
    /// down between tracks. Mirrors the Yandex Music client's two-player
    /// "preheat + swap" scheme.
    preheat: Option<Arc<Player>>,
    /// Player of the previous track during a crossfade: keeps playing its tail
    /// while fading out, stopped by `finish_crossfade` (or by any hard stop).
    outgoing: Option<Arc<Player>>,
    // Last user volume applied to the players; a newly parked preheat player
    // inherits it so the parked slot stays silent in step with the output.
    volume: f32,
    // Crossfade gain factors on top of `volume`, animated by the controller:
    // the promoted player ramps 0→1 while the outgoing one ramps 1→0.
    sink_fade: f32,
    outgoing_fade: f32,
}

impl EnginePlayers {
    fn new(sink: Arc<Player>) -> Self {
        Self {
            sink,
            preheat: None,
            outgoing: None,
            volume: 1.0,
            sink_fade: 1.0,
            outgoing_fade: 1.0,
        }
    }

    fn reset_fades(&mut self) {
        self.sink_fade = 1.0;
        self.outgoing_fade = 1.0;
    }

    /// Audible volume per slot is `volume * fade`; keeps every live slot in
    /// step after any fader or volume change.
    fn apply_mix(&self) {
        self.sink.set_volume(self.volume * self.sink_fade);
        if let Some(outgoing) = &self.outgoing {
            outgoing.set_volume(self.volume * self.outgoing_fade);
        }
        // The parked preheat plays at full user volume once promoted; its
        // fade-in is `sink_fade`, applied by the same helper after promotion.
        if let Some(preheat) = &self.preheat {
            preheat.set_volume(self.volume);
        }
    }

    fn append<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        self.sink.append(source);
    }

    /// Parks the next track's player (already attached to the mixer) paused,
    /// at the current user volume. A previously parked player, if any, is
    /// dropped — `Player::drop` stops its queue.
    fn park(&mut self, player: Player) {
        let player = Arc::new(player);
        player.set_volume(self.volume);
        player.pause();
        self.preheat = Some(player);
    }

    fn has_preheat(&self) -> bool {
        self.preheat.is_some()
    }

    /// Discards the parked preheat player without touching the current one.
    /// Dropping the `Player` marks its queue stopped, so the mixer detaches it
    /// on the next callback tick and the session's decoder thread winds down.
    fn drop_preheat(&mut self) {
        self.preheat.take();
    }

    /// Common promotion path: the parked preheat player starts and becomes the
    /// sink; the previous sink moves to the outgoing slot (hard swap stops it
    /// right away, crossfade lets it play into the fade window).
    ///
    /// The faders are applied AFTER the slot swap and BEFORE the new player
    /// starts: the promoted player is still parked-paused at that point, so
    /// nothing reaches the mixer at the wrong gain — the new sink starts at
    /// its fade-in gain (zero for a crossfade), the outgoing at its fade-out
    /// gain. Applying before the swap would mute the outgoing for one mixer
    /// callback and pop it back on the first ramp step, audible as a click.
    fn promote_preheat(&mut self, crossfade: bool) -> bool {
        let Some(player) = self.preheat.take() else {
            return false;
        };
        // A replaced outgoing still fades from a previous transition: hard
        // swap or a new fade both end it here, never drop it silently.
        if let Some(prev) = self.outgoing.take() {
            prev.stop();
        }
        if crossfade {
            self.sink_fade = 0.0;
            self.outgoing_fade = 1.0;
        } else {
            self.reset_fades();
        }
        let old = std::mem::replace(&mut self.sink, player);
        if crossfade {
            self.outgoing = Some(old);
        } else {
            // Hard swap: the outgoing playback is over — stop the old player
            // instead of leaking its remainder into the new track.
            old.stop();
        }
        self.apply_mix();
        self.sink.play();
        true
    }

    /// Seamlessly promotes the preheated player to be the current one: starts
    /// it, stops the outgoing player and swaps the slots. Returns `false` when
    /// there is nothing to promote (or the engine was recreated meanwhile) —
    /// the caller falls back to the poll-based advance path.
    fn activate_preheat(&mut self) -> bool {
        self.promote_preheat(false)
    }

    /// Crossfade promotion: like `activate_preheat`, but the outgoing player
    /// keeps playing into the fade-out window instead of being stopped. The
    /// caller animates both faders (`set_fade`) and completes the transition
    /// with `finish_crossfade`.
    fn begin_crossfade(&mut self) -> bool {
        self.promote_preheat(true)
    }

    /// Ends a crossfade: stops the fading-out player (it reached the end of
    /// its fade window) and restores unity gain on the current one.
    fn finish_crossfade(&mut self) {
        if let Some(outgoing) = self.outgoing.take() {
            outgoing.stop();
        }
        self.reset_fades();
        self.apply_mix();
    }

    /// Updates both crossfade faders; each player's audible volume is
    /// `volume * fade`. Called from the ramp animation task.
    fn set_fade(&mut self, sink_fade: f32, outgoing_fade: f32) {
        self.sink_fade = sink_fade.clamp(0.0, 1.0);
        self.outgoing_fade = outgoing_fade.clamp(0.0, 1.0);
        self.apply_mix();
    }

    /// The player currently feeding the output, for boundary watching
    /// (`Player::sleep_until_end` gives a sample-accurate end signal).
    fn current_player(&self) -> Arc<Player> {
        self.sink.clone()
    }

    fn set_volume(&mut self, volume: f32) {
        self.volume = volume;
        self.apply_mix();
    }

    fn pause(&self) {
        self.sink.pause();
        if let Some(outgoing) = &self.outgoing {
            outgoing.pause();
        }
    }

    fn play(&self) {
        self.sink.play();
        if let Some(outgoing) = &self.outgoing {
            outgoing.play();
        }
    }

    fn stop(&mut self) {
        // The parked preheat and the fading-out player belong to the outgoing
        // playback just as much as the current source: any stop (user stop,
        // skip, soft reload, device change) invalidates all three.
        self.preheat.take();
        if let Some(outgoing) = self.outgoing.take() {
            outgoing.stop();
        }
        self.reset_fades();
        self.apply_mix();
        self.sink.stop();
    }

    fn is_empty(&self) -> bool {
        self.sink.empty()
    }

    fn pos(&self) -> std::time::Duration {
        self.sink.get_pos()
    }

    fn try_seek(&self, pos: std::time::Duration) -> Result<(), rodio::source::SeekError> {
        self.sink.try_seek(pos)
    }
}

struct EngineState {
    _stream: MixerDeviceSink,
    players: EnginePlayers,
    sample_rate: NonZero<u32>,
    channels: NonZero<u16>,
}

pub struct PlaybackEngine {
    state: parking_lot::RwLock<Option<EngineState>>,
    tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>,
}

impl PlaybackEngine {
    pub fn new(
        tx: tokio::sync::mpsc::Sender<crate::audio::commands::AudioMessage>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let engine = Self {
            state: parking_lot::RwLock::new(None),
            tx,
        };
        engine.recreate(None)?;
        Ok(engine)
    }

    pub fn recreate(
        &self,
        device_name: Option<&str>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (device, stream_config, sample_format) = setup_device_config(device_name)?;

        let tx_clone = self.tx.clone();
        let error_callback = move |err: rodio::cpal::Error| {
            match err.kind() {
                // cpal already recovers an xrun internally (prepare/try_recover), so
                // recreating the stream here would only drop audio — and on VMs where
                // underruns are constant, turn every glitch into an endless recreate loop.
                rodio::cpal::ErrorKind::Xrun => {
                    tracing::debug!("audio_stream_underrun");
                }
                _ => {
                    tracing::error!(error = ?err, "audio_stream_error");
                    let _ = tx_clone.try_send(crate::audio::commands::AudioMessage::RecreateStream);
                }
            }
        };

        let (stream, sink) = construct_sink(device, &stream_config, sample_format, error_callback)?;

        // Trust what was actually opened: a fallback config may differ from
        // the device default we asked for, and resampling to the wrong
        // rate/channels would speed up or slow down every track.
        let actual = stream.config();
        let sample_rate = actual.sample_rate();
        let channels = actual.channel_count();

        *self.state.write() = Some(EngineState {
            _stream: stream,
            players: EnginePlayers::new(Arc::new(sink)),
            sample_rate,
            channels,
        });
        Ok(())
    }

    fn wrap_source<S>(state: &EngineState, source: S) -> rodio::source::UniformSourceIterator<S>
    where
        S: Source<Item = f32> + Send + 'static,
    {
        rodio::source::UniformSourceIterator::new(source, state.channels, state.sample_rate)
    }

    pub fn play_source<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        if let Some(state) = self.state.read().as_ref() {
            let resampled = Self::wrap_source(state, source);
            state.players.append(resampled);
        }
    }

    /// Parks the next track's source on a second, paused player attached to the
    /// same device mixer. While parked, the source is polled by the mixer but
    /// yields silence without advancing — position stays at zero and no decode
    /// output is consumed, so the preheated session survives untouched until
    /// promotion. Any previously parked source is dropped first.
    pub fn preheat_source<S>(&self, source: S)
    where
        S: Source<Item = f32> + Send + 'static,
    {
        let mut state_guard = self.state.write();
        let Some(state) = state_guard.as_mut() else {
            return;
        };
        let resampled = Self::wrap_source(state, source);
        let player = Player::connect_new(state._stream.mixer());
        player.append(resampled);
        state.players.park(player);
    }

    pub fn has_preheat(&self) -> bool {
        self.state
            .read()
            .as_ref()
            .map(|s| s.players.has_preheat())
            .unwrap_or(false)
    }

    pub fn drop_preheat(&self) {
        if let Some(state) = self.state.write().as_mut() {
            state.players.drop_preheat();
        }
    }

    pub fn activate_preheat(&self) -> bool {
        self.state
            .write()
            .as_mut()
            .map(|s| s.players.activate_preheat())
            .unwrap_or(false)
    }

    pub fn begin_crossfade(&self) -> bool {
        self.state
            .write()
            .as_mut()
            .map(|s| s.players.begin_crossfade())
            .unwrap_or(false)
    }

    pub fn finish_crossfade(&self) {
        if let Some(state) = self.state.write().as_mut() {
            state.players.finish_crossfade();
        }
    }

    pub fn set_fade(&self, sink_fade: f32, outgoing_fade: f32) {
        if let Some(state) = self.state.write().as_mut() {
            state.players.set_fade(sink_fade, outgoing_fade);
        }
    }

    pub fn current_player(&self) -> Option<Arc<Player>> {
        self.state
            .read()
            .as_ref()
            .map(|s| s.players.current_player())
    }

    pub fn set_volume(&self, volume: f32) {
        if let Some(state) = self.state.write().as_mut() {
            state.players.set_volume(volume);
        }
    }

    pub fn pause(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.players.pause();
        }
    }

    pub fn play(&self) {
        if let Some(state) = self.state.read().as_ref() {
            state.players.play();
        }
    }

    pub fn stop(&self) {
        if let Some(state) = self.state.write().as_mut() {
            state.players.stop();
        }
    }

    pub fn is_empty(&self) -> bool {
        self.state
            .read()
            .as_ref()
            .map(|s| s.players.is_empty())
            .unwrap_or(true)
    }

    pub fn pos(&self) -> std::time::Duration {
        self.state
            .read()
            .as_ref()
            .map(|s| s.players.pos())
            .unwrap_or_default()
    }

    pub fn try_seek(
        &self,
        pos: std::time::Duration,
    ) -> std::result::Result<(), rodio::source::SeekError> {
        if let Some(state) = self.state.read().as_ref() {
            state.players.try_seek(pos)
        } else {
            Err(rodio::source::SeekError::NotSupported {
                underlying_source: "Stream not initialized",
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::buffer::SamplesBuffer;
    use std::time::{Duration, Instant};

    /// Drains the mixer output the way the device callback would, so queued
    /// sources actually advance. Bounded so the test thread always exits.
    fn drain_output(mut output: rodio::mixer::MixerSource, seconds: u64) {
        std::thread::spawn(move || {
            let budget = Instant::now() + Duration::from_secs(seconds);
            while Instant::now() < budget {
                // The mixer returns None while it has no sources yet (the
                // queue sources are attached right after this thread starts),
                // so keep pulling instead of exiting on the first None.
                if output.next().is_none() {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
        });
    }

    fn one_second_buffer() -> SamplesBuffer {
        SamplesBuffer::new(
            NonZero::new(2).unwrap(),
            NonZero::new(44100).unwrap(),
            vec![0.5f32; 44100 * 2],
        )
    }

    /// Long enough that the (unpaced) drain thread cannot exhaust it during
    /// the test, so queue-membership assertions stay stable.
    fn long_buffer() -> SamplesBuffer {
        SamplesBuffer::new(
            NonZero::new(2).unwrap(),
            NonZero::new(44100).unwrap(),
            vec![0.5f32; 44100 * 2 * 60],
        )
    }

    /// Device-free slot machinery against a standalone mixer. The mixer must
    /// stay in scope for the players to remain attached.
    fn engine_players() -> (rodio::mixer::Mixer, EnginePlayers) {
        let (mixer, output) =
            rodio::mixer::mixer(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap());
        drain_output(output, 5);
        let sink = Arc::new(Player::connect_new(&mixer));
        (mixer, EnginePlayers::new(sink))
    }

    /// Loads the sink with a long buffer so it plays for the whole test.
    fn load_sink(players: &EnginePlayers) {
        players.append(long_buffer());
    }

    /// Parks a preheated next track, the way `preheat_source` does.
    fn park_next(mixer: &rodio::mixer::Mixer, players: &mut EnginePlayers) {
        let player = Player::connect_new(mixer);
        player.append(long_buffer());
        players.park(player);
    }

    fn assert_vol(actual: f32, expected: f32) {
        assert!(
            (actual - expected).abs() < 1e-4,
            "volume {actual} != {expected}"
        );
    }

    #[test]
    fn strict_swap_stops_outgoing_instead_of_overlapping() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);
        assert!(players.has_preheat());

        let old = players.current_player();
        // Old track mid-play: the strict swap is the skip-with-preheat path.
        std::thread::sleep(Duration::from_millis(60));
        assert!(players.activate_preheat());

        // The outgoing playback is over — stopped, not mixed over the new
        // track; the promoted one plays at full user volume.
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(old.len(), 0, "strict swap must stop the old player");
        assert!(players.pos() > Duration::ZERO);
        assert!(!players.has_preheat());
        assert_vol(players.sink.volume(), 1.0);
        assert!(players.outgoing.is_none());

        // Nothing left to promote.
        assert!(!players.activate_preheat());
    }

    #[test]
    fn crossfade_promotion_starts_new_muted_and_outgoing_full() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);

        let old = players.current_player();
        assert!(players.begin_crossfade());
        let new_sink = players.current_player();

        // Faders are applied before the promoted player starts: it must not
        // emit a single buffer at full volume, and the outgoing must not be
        // muted for a callback and then pop back on the first ramp step.
        assert_vol(new_sink.volume(), 0.0);
        assert_vol(old.volume(), 1.0);

        // Both queues stay live and mixing during the overlap.
        assert_eq!(old.len(), 1);
        assert_eq!(new_sink.len(), 1);
        std::thread::sleep(Duration::from_millis(80));
        assert!(new_sink.get_pos() > Duration::ZERO);
    }

    #[test]
    fn set_fade_drives_slot_gains_and_finish_restores_them() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);
        players.begin_crossfade();
        let old = players.outgoing.clone().expect("outgoing after crossfade");

        players.set_fade(0.25, 0.75);
        assert_vol(players.sink.volume(), 0.25);
        assert_vol(old.volume(), 0.75);

        // Out-of-range faders clamp.
        players.set_fade(-1.0, 2.0);
        assert_vol(players.sink.volume(), 0.0);
        assert_vol(old.volume(), 1.0);

        // Finish: the fading-out player stops, the current returns to unity.
        players.finish_crossfade();
        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(old.len(), 0);
        assert!(players.outgoing.is_none());
        assert_vol(players.sink.volume(), 1.0);
    }

    #[test]
    fn replaced_outgoing_is_stopped_not_leaked() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);
        players.begin_crossfade();
        let first_outgoing = players.outgoing.clone().expect("first outgoing");

        // A second crossfade without finishing the first (rapid transition):
        // the stale outgoing must be stopped, never dropped silently.
        park_next(&mixer, &mut players);
        assert!(players.begin_crossfade());

        std::thread::sleep(Duration::from_millis(60));
        assert_eq!(first_outgoing.len(), 0, "replaced outgoing must stop");
    }

    #[test]
    fn stop_clears_preheat_outgoing_and_fades() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);
        players.begin_crossfade();
        let old = players.outgoing.clone().expect("outgoing");
        players.set_fade(0.3, 0.7);

        players.stop();
        std::thread::sleep(Duration::from_millis(60));

        assert_eq!(old.len(), 0);
        assert!(!players.has_preheat());
        assert!(players.outgoing.is_none());
        assert!(players.is_empty());
        // Faders reset: the next append starts at unity gain.
        assert_vol(players.sink.volume(), 1.0);
    }

    #[test]
    fn pause_and_resume_cover_both_slots() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);
        players.begin_crossfade();
        let old = players.outgoing.clone().expect("outgoing");

        players.pause();
        assert!(players.sink.is_paused());
        assert!(old.is_paused());

        players.play();
        assert!(!players.sink.is_paused());
        assert!(!old.is_paused());
    }

    #[test]
    fn drop_preheat_keeps_current_playback() {
        let (mixer, mut players) = engine_players();
        load_sink(&players);
        park_next(&mixer, &mut players);

        players.drop_preheat();
        assert!(!players.has_preheat());
        assert_eq!(players.sink.len(), 1);
        // Dropping again is a no-op.
        players.drop_preheat();
        assert_eq!(players.sink.len(), 1);
    }

    #[test]
    fn crossfade_sequence_keeps_outgoing_mixed_until_finish() {
        let (mixer, output) =
            rodio::mixer::mixer(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap());
        drain_output(output, 5);

        let outgoing = Arc::new(Player::connect_new(&mixer));
        outgoing.append(long_buffer());
        assert_eq!(outgoing.len(), 1);

        // Park the next track the way preheat does, then promote it the way
        // `begin_crossfade` does: play it WITHOUT stopping the outgoing one.
        let promoted = Arc::new(Player::connect_new(&mixer));
        promoted.append(long_buffer());
        promoted.pause();
        promoted.play();

        // Both queues are live and mixing simultaneously during the overlap.
        assert_eq!(outgoing.len(), 1);
        assert_eq!(promoted.len(), 1);
        std::thread::sleep(Duration::from_millis(80));
        assert!(promoted.get_pos() > Duration::ZERO);

        // `finish_crossfade`: the fading-out player stops, the promoted one
        // is untouched.
        outgoing.stop();
        std::thread::sleep(Duration::from_millis(80));
        assert_eq!(outgoing.len(), 0);
        assert_eq!(promoted.len(), 1);
    }

    #[test]
    fn parked_preheat_player_holds_position_and_promotes_seamlessly() {
        let (mixer, output) =
            rodio::mixer::mixer(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap());
        drain_output(output, 5);

        let current = Arc::new(Player::connect_new(&mixer));
        current.append(one_second_buffer());

        let preheat = Arc::new(Player::connect_new(&mixer));
        preheat.append(one_second_buffer());
        preheat.pause();

        // Parked: the mixer polls the paused source but it yields silence
        // without advancing — the preheated source must remain untouched.
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(preheat.len(), 1);
        assert_eq!(preheat.get_pos(), Duration::ZERO);

        // Promote: the swap must not disturb the parked source's position.
        preheat.play();
        current.stop();
        std::thread::sleep(Duration::from_millis(150));
        assert!(preheat.get_pos() > Duration::ZERO);
        assert_eq!(current.len(), 0);
    }

    #[test]
    fn boundary_watch_wakes_when_current_source_ends() {
        let (mixer, output) =
            rodio::mixer::mixer(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap());
        drain_output(output, 5);

        let current = Arc::new(Player::connect_new(&mixer));
        // 0.25 s of audio.
        current.append(SamplesBuffer::new(
            NonZero::new(2).unwrap(),
            NonZero::new(44100).unwrap(),
            vec![0.0f32; 44100 / 2],
        ));

        let started = Instant::now();
        current.sleep_until_end();
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "sleep_until_end must wake promptly at the end of the source"
        );
    }

    #[test]
    fn drop_preheat_detaches_only_the_parked_player() {
        let (mixer, output) =
            rodio::mixer::mixer(NonZero::new(2).unwrap(), NonZero::new(44100).unwrap());
        drain_output(output, 5);

        // Paused so the (unpaced) drain thread cannot consume it — the test
        // only asserts about queue membership, not playback progress.
        let current = Arc::new(Player::connect_new(&mixer));
        current.append(one_second_buffer());
        current.pause();

        let preheat = Arc::new(Player::connect_new(&mixer));
        preheat.append(one_second_buffer());
        preheat.pause();

        preheat.stop();
        drop(preheat);
        std::thread::sleep(Duration::from_millis(150));

        // The current player is untouched by the parked slot going away.
        assert_eq!(current.len(), 1);
        assert!(current.is_paused());
    }
}
