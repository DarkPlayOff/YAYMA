import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/layout/mobile_full_player.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
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

Future<void> _mount(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
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

  await tester.pumpWidget(
    const MaterialApp(
      home: MobileFullPlayer(
        plateRect: Rect.fromLTWH(0, 700, 360, 400),
        coverRect: Rect.fromLTWH(20, 100, 300, 300),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 2));
  // Only the open pane's slider is laid out; the collapsed one is a copy.
  expect(tester.takeException(), isNull);
}

/// The content column: every row under the cover shares this rect.
Rect _column(WidgetTester tester) =>
    tester.getRect(find.byType(CommonProgressSlider).first);

/// The artwork at rest: the one nearest the window centre (the neighbours are
/// mounted off-screen).
Rect _cover(WidgetTester tester, Size size) {
  final rects =
      [
        for (final image in tester.widgetList<RustCachedImage>(
          find.byType(RustCachedImage),
        ))
          if (image.placeholder != null) tester.getRect(find.byWidget(image)),
      ]..sort(
        (a, b) => (a.center.dx - size.width / 2).abs().compareTo(
          (b.center.dx - size.width / 2).abs(),
        ),
      );
  return rects.first;
}

void main() {
  testWidgets('the full player column is centred on a tablet window', (
    tester,
  ) async {
    const size = Size(1280, 800);
    await _mount(tester, size);

    // Was pinned to the left edge, leaving the right half of the screen empty
    // while the header above it stayed centred.
    expect(_column(tester).center.dx, moreOrLessEquals(size.width / 2));
    // The cover is height-limited here, so it must be centred in the column
    // rather than hanging on its left edge.
    expect(_cover(tester, size).center.dx, moreOrLessEquals(size.width / 2));
  });

  testWidgets('a phone window keeps the column at the left edge', (
    tester,
  ) async {
    const size = Size(360, 780);
    await _mount(tester, size);

    // The phone layout is deliberately left-aligned, not centred.
    expect(_column(tester).left, moreOrLessEquals(20));
  });
}
