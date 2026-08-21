import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
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

  static const _duckGain = 20;
  static const _duckFadeDuration = Duration(milliseconds: 200);
  static const _duckFadeSteps = 10;

  static Future<void> initialize(AudioSession session) async {
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    _resumeAfterTransient = false;
    _transientPauseActive = false;
    _ducked = false;
    _sessionActive = false;
    _transientGain = 100;
    await PlaybackController.changeTransientVolumeGain(100);

    _interruptionSub = session.interruptionEventStream.listen(
      (event) {
        _interruptionQueue = _interruptionQueue.then(
          (_) => _handleInterruption(event),
        );
      },
      onError: (Object e, StackTrace st) {
        debugPrint('Audio interruption stream error: $e');
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
        debugPrint('Audio becoming-noisy stream error: $e');
      },
    );

    _disposeSessionActiveEffect?.call();
    _disposeSessionActiveEffect = effect(() {
      final isPlaying = playerStateSignal()?.isPlaying ?? false;
      _sessionQueue = _sessionQueue.then(
        (_) => _syncSessionActive(session, isPlaying),
      );
    });
  }

  static Future<void> _handleInterruption(
    AudioInterruptionEvent event,
  ) async {
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
      debugPrint('Audio interruption handling failed: $e\n$st');
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
      debugPrint('Audio becoming-noisy handling failed: $e\n$st');
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
      debugPrint('Failed to sync audio session active state: $e\n$st');
    }
  }
}
