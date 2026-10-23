import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/mobile_cover_swipe.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

SimpleTrackDto _track(String id) => SimpleTrackDto(
  id: id,
  title: id,
  artists: const [],
  durationMs: 1000,
  coverUrl: '$id.jpg',
  isLiked: false,
  isDisliked: false,
);

PlaybackState _state({required String trackId, required int index}) =>
    PlaybackState(
      isPlaying: true,
      isBuffering: false,
      volume: 100,
      isMuted: false,
      repeatMode: RepeatModeDto.none,
      isShuffled: false,
      queueCount: 3,
      queueIndex: index,
      currentTrack: _track(trackId),
      currentWaveSeeds: const [],
    );

/// Builds a controller already sliding from track "a" to "b", then settles the
/// commit animation while playback still reports "a".
Future<
  ({
    CoverSwipeController swipe,
    AnimationController animation,
    List<int> changes,
  })
>
_settledCommit(WidgetTester tester) async {
  playerStateSignal.value = _state(trackId: 'a', index: 0);
  final animation = AnimationController(vsync: const TestVSync());
  final changes = <int>[];
  final swipe = CoverSwipeController(
    animation: animation,
    travel: () => 300,
    canAnimate: () => true,
    isMounted: () => true,
    onNext: () {},
    onPrevious: () {},
    onChanged: () => changes.add(1),
    initialTrackId: 'a',
    initialCoverUrl: 'a.jpg',
    initialIndex: 0,
  );
  // Queue index moves 0 -> 1, so the direction is known without the
  // asynchronous queue list.
  playerStateSignal.value = _state(trackId: 'a', index: 1);
  swipe.onTrackChange(trackId: 'b', coverUrl: 'b.jpg');
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return (swipe: swipe, animation: animation, changes: changes);
}

void main() {
  testWidgets('watchdog returns the artwork to the live track', (tester) async {
    final commit = await _settledCommit(tester);
    expect(commit.swipe.holdUrl, 'b.jpg', reason: 'incoming art is held');
    expect(commit.changes, isEmpty);

    await tester.pump(kCoverSettleTimeout);

    expect(commit.swipe.holdUrl, isNull, reason: 'artwork is released');
    expect(commit.changes, hasLength(1), reason: 'cover is repainted');
  });

  testWidgets('closing the player cancels the watchdog', (tester) async {
    final commit = await _settledCommit(tester);
    expect(commit.swipe.holdUrl, 'b.jpg');

    commit.swipe.reset();

    await tester.pump(kCoverSettleTimeout);

    expect(commit.swipe.holdUrl, isNull);
    expect(commit.changes, isEmpty, reason: 'nothing to repaint');
  });
}
