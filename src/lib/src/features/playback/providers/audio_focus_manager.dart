import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/services/app_logger.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Bridges audio_session interruptions to the Rust playback engine.
///
/// The transitions mirror Media3/ExoPlayer: permanent loss stops playback
/// without resuming, transient loss pauses and resumes only if playback was
/// active before the interruption, and ducking applies a 0.2 multiplier.
class AudioFocusManager {
  AudioFocusManager._();

  static StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  static StreamSubscription<void>? _becomingNoisySub;
  static EffectCleanup? _disposeSessionActiveEffect;
  static Future<void> _interruptionQueue = Future.value();
  static Future<void> _sessionQueue = Future.value();
  static bool _resumeAfterTransient = false;
  static bool _transientPauseActive = false;
  static bool _ducked = false;
  static bool _sessionActive = false;
  static int _transientGain = 100;
  static bool _lastObservedPlaying = false;

  static const _duckGain = 20;
  static const _duckFadeDuration = Duration(milliseconds: 200);
  static const _duckFadeSteps = 10;

  static Future<void> initialize(AudioSession session) async {
    await dispose();
    await PlaybackController.changeTransientVolumeGain(100);

    _interruptionSub = session.interruptionEventStream.listen(
      (event) {
        _interruptionQueue = _interruptionQueue.then(
          (_) => _handleInterruption(event),
        );
      },
      onError: (Object e, StackTrace st) {
        appLog(AppLogLevel.warn, 'audio interruption stream error: $e');
      },
    );

    // ExoPlayer pauses when the audio route becomes noisy, for example when
    // wired headphones are unplugged, and does not resume automatically.
    _becomingNoisySub = session.becomingNoisyEventStream.listen(
      (_) {
        _interruptionQueue = _interruptionQueue.then(
          (_) => _handleBecomingNoisy(),
        );
      },
      onError: (Object e, StackTrace st) {
        appLog(AppLogLevel.warn, 'audio becoming-noisy stream error: $e');
      },
    );

    _disposeSessionActiveEffect?.call();
    _disposeSessionActiveEffect = effect(() {
      final isPlaying = playerStateSignal()?.isPlaying ?? false;
      _onPlayingObserved(isPlaying);
      _sessionQueue = _sessionQueue.then(
        (_) => _syncSessionActive(session, isPlaying),
      );
    });
  }

  /// Explicit teardown for app shutdown: cancels interruption/noisy
  /// subscriptions and the session-sync effect, then resets in-memory state
  /// so a later [initialize] starts clean. Idempotent; makes no Rust calls
  /// so it is safe to invoke after logout when there is no app context.
  static Future<void> dispose() async {
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    await _becomingNoisySub?.cancel();
    _becomingNoisySub = null;
    _disposeSessionActiveEffect?.call();
    _disposeSessionActiveEffect = null;
    _interruptionQueue = Future.value();
    _sessionQueue = Future.value();
    _resumeAfterTransient = false;
    _transientPauseActive = false;
    _ducked = false;
    _sessionActive = false;
    _transientGain = 100;
    _lastObservedPlaying = false;
  }

  /// While a transient interruption has the player paused, only a manual
  /// action can RAISE the playing flag: this manager resumes after clearing
  /// the transient state, and its own begin-pause only ever lowers it. An
  /// observed rise (not just a re-run with `true`, which any unrelated
  /// state event can cause) therefore means the user acted during the call
  /// — they take over, and the interruption-end must not auto-resume on
  /// top of a later explicit pause.
  static void _onPlayingObserved(bool isPlaying) {
    if (isPlaying && !_lastObservedPlaying && _transientPauseActive) {
      _transientPauseActive = false;
      _resumeAfterTransient = false;
    }
    _lastObservedPlaying = isPlaying;
  }

  static Future<void> _handleInterruption(AudioInterruptionEvent event) async {
    try {
      switch (event.type) {
        case AudioInterruptionType.duck:
          if (event.begin) {
            if (!_ducked) {
              _ducked = true;
              await _fadeGainTo(_duckGain);
            }
          } else if (_ducked) {
            _ducked = false;
            await _fadeGainTo(100);
          }
        case AudioInterruptionType.pause:
          if (event.begin) {
            // Focus systems report state changes, not stacks: while a
            // transient loss is already active, Android delivers no event
            // for another identical loss, so a second begin is a platform
            // echo. Keeping the first begin's frozen resume intent keeps it
            // paired with the single pause-end that will follow.
            if (_transientPauseActive) return;
            // A stronger interruption supersedes ducking. Android clears its
            // duck state here and later sends pause-end, not duck-end, so the
            // transient gain must be restored before pausing.
            if (_ducked) {
              _ducked = false;
              await _fadeGainTo(100);
            }
            _transientPauseActive = true;
            _resumeAfterTransient = isPlayingSignal.value;
            if (_resumeAfterTransient) await PlaybackController.pause();
          } else if (_transientPauseActive) {
            _transientPauseActive = false;
            final shouldResume = _resumeAfterTransient;
            _resumeAfterTransient = false;
            if (shouldResume) await PlaybackController.play();
          }
        case AudioInterruptionType.unknown:
          // Android sends this for permanent focus loss and abandons focus.
          // Do not resume automatically after it.
          if (event.begin) {
            _transientPauseActive = false;
            _resumeAfterTransient = false;
            if (_ducked) {
              _ducked = false;
              await _fadeGainTo(100);
            }
            if (isPlayingSignal.value) await PlaybackController.pause();
          }
      }
    } on Object catch (e, st) {
      appLog(AppLogLevel.warn, 'audio interruption handling failed: $e $st');
    }
  }

  static Future<void> _handleBecomingNoisy() async {
    try {
      _resumeAfterTransient = false;
      _transientPauseActive = false;
      if (_ducked) {
        _ducked = false;
        await _fadeGainTo(100);
      }
      if (isPlayingSignal.value) await PlaybackController.pause();
    } on Object catch (e, st) {
      appLog(AppLogLevel.warn, 'audio becoming-noisy handling failed: $e $st');
    }
  }

  static Future<void> _fadeGainTo(int target) async {
    final start = _transientGain;
    if (start == target) return;

    final stepDelay = _duckFadeDuration ~/ _duckFadeSteps;
    for (var step = 1; step <= _duckFadeSteps; step++) {
      final progress = step / _duckFadeSteps;
      _transientGain = (start + (target - start) * progress).round().clamp(
        0,
        100,
      );
      await PlaybackController.changeTransientVolumeGain(_transientGain);
      if (step < _duckFadeSteps) await Future<void>.delayed(stepDelay);
    }
  }

  static Future<void> _syncSessionActive(
    AudioSession session,
    bool isPlaying,
  ) async {
    try {
      if (isPlaying) {
        if (_sessionActive) return;
        final granted = await session.setActive(true);
        _sessionActive = granted;
        if (!granted) await PlaybackController.pause();
      } else {
        // Keep the session active during transient interruption so the
        // matching focus-gain callback can arrive.
        if (_transientPauseActive || !_sessionActive) return;
        await session.setActive(false);
        _sessionActive = false;
      }
    } on Object catch (e, st) {
      appLog(AppLogLevel.warn, 'audio session active sync failed: $e $st');
    }
  }
}
