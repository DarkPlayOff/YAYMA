import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/mobile_full_player.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

const _track = SimpleTrackDto(
  id: 'a',
  title: 'Track',
  artists: [],
  durationMs: 1000,
  coverUrl: 'a.jpg',
  isLiked: false,
  isDisliked: false,
);

/// Mounts an open full player, the way the mini player's tap leaves it.
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  playerStateSignal.value = const PlaybackState(
    isPlaying: true,
    isBuffering: false,
    volume: 100,
    isMuted: false,
    repeatMode: RepeatModeDto.none,
    isShuffled: false,
    queueCount: 1,
    queueIndex: 0,
    queueRevision: 0,
    currentTrack: _track,
    currentWaveSeeds: [],
  );
  queueNeighborhoodSignal.setValue(
    const QueueNeighborhoodDto(tracks: [_track]),
  );
  mobileFullPlayerController.reset();
  mobileFullPlayerOpenSignal.value = true;

  await tester.pumpWidget(
    const MaterialApp(
      home: MobileFullPlayer(
        plateRect: Rect.fromLTWH(0, 700, 360, 400),
        coverRect: Rect.fromLTWH(20, 100, 300, 300),
      ),
    ),
  );
  // Entrance spring.
  await tester.pump(const Duration(seconds: 2));
  expect(tester.takeException(), isNull);
  expect(mobileFullPlayerProgress.value, closeTo(1, 0.01));
}

/// Sends a backgesture method call; returns the decoded reply for the
/// `startBackGesture` claim check, otherwise null.
Future<Object?> _sendBack(
  WidgetTester tester,
  String method, [
  Map<String, Object?>? arguments,
]) async {
  Object? reply;
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    data,
    (bytes) {
      if (bytes == null || bytes.lengthInBytes == 0) {
        reply = null;
        return;
      }
      try {
        reply = const StandardMethodCodec().decodeEnvelope(bytes);
      } on PlatformException {
        reply = null;
      }
    },
  );
  return reply;
}

Map<String, Object?> _touchEvent(double progress) => {
  'touchOffset': <double>[20, 400],
  'progress': progress,
  'swipeEdge': 0,
};

void main() {
  testWidgets('a back gesture collapses the player and closes it on commit', (
    tester,
  ) async {
    await _open(tester);

    expect(await _sendBack(tester, 'startBackGesture', _touchEvent(0)), isTrue);

    await _sendBack(tester, 'updateBackGestureProgress', _touchEvent(0.5));
    await tester.pump(const Duration(milliseconds: 16));
    expect(mobileFullPlayerProgress.value, closeTo(0.5, 0.01));

    await _sendBack(tester, 'updateBackGestureProgress', _touchEvent(0.8));
    await tester.pump(const Duration(milliseconds: 16));
    expect(mobileFullPlayerProgress.value, closeTo(0.2, 0.01));

    await _sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(mobileFullPlayerOpenSignal.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the gesture returns the player to full screen', (
    tester,
  ) async {
    await _open(tester);

    expect(await _sendBack(tester, 'startBackGesture', _touchEvent(0)), isTrue);
    await _sendBack(tester, 'updateBackGestureProgress', _touchEvent(0.6));
    await tester.pump(const Duration(milliseconds: 16));

    await _sendBack(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();

    expect(mobileFullPlayerOpenSignal.value, isTrue);
    expect(mobileFullPlayerProgress.value, closeTo(1, 0.01));
  });

  testWidgets('the back button is not claimed and keeps the pop behaviour', (
    tester,
  ) async {
    await _open(tester);

    // A button press has no touch offset: the player does not claim it, and
    // the framework falls back to a plain pop, which the player's PopScope
    // turns into the spring close — the same path as on a device.
    final claimed = await _sendBack(tester, 'startBackGesture', {
      'progress': 0.0,
    });
    expect(claimed, isNot(isTrue));
    expect(mobileFullPlayerProgress.value, closeTo(1, 0.01));

    await _sendBack(tester, 'commitBackGesture');
    await tester.pumpAndSettle();

    expect(mobileFullPlayerOpenSignal.value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
