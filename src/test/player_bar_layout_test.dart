import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/layout/mobile_mini_player.dart';
import 'package:yayma/src/features/core/views/layout/player_bar.dart';
import 'package:yayma/src/features/core/views/layout/player_lyrics.dart';
import 'package:yayma/src/features/home/views/home_view.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

SimpleTrackDto _track() => const SimpleTrackDto(
  id: 'a',
  title: 'Track',
  artists: [],
  durationMs: 1000,
  coverUrl: 'a.jpg',
  isLiked: false,
  isDisliked: false,
);

void _publishTrack() {
  playerStateSignal.value = PlaybackState(
    isPlaying: true,
    isBuffering: false,
    volume: 100,
    isMuted: false,
    repeatMode: RepeatModeDto.none,
    isShuffled: false,
    queueCount: 1,
    queueIndex: 0,
    queueRevision: 0,
    currentTrack: _track(),
    currentWaveSeeds: const [],
  );
}

/// Renders a widget at [width] x [height] and fails on any layout error.
Future<void> _pumpAt(
  WidgetTester tester,
  Widget widget,
  double width, {
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _publishTrack();

  await tester.pumpWidget(MaterialApp(home: Scaffold(body: widget)));
  await tester.pump();

  expect(
    tester.takeException(),
    isNull,
    reason: 'layout failed at ${width}x$height',
  );
}

void main() {
  testWidgets('player bar picks one layout per width, without overflow', (
    tester,
  ) async {
    // The desktop window minimum is 800 wide, so 800 and up is desktop.
    await _pumpAt(tester, const PlayerBar(), 800);
    expect(find.byType(MobileMiniPlayer), findsNothing);

    await _pumpAt(tester, const PlayerBar(), 1280);
    expect(find.byType(MobileMiniPlayer), findsNothing);

    // Host tests run on a desktop platform, so only the compact breakpoint can
    // make this narrow here.
    await _pumpAt(tester, const PlayerBar(), 420);
    expect(find.byType(MobileMiniPlayer), findsOneWidget);
  });

  testWidgets('home fits phone, tablet and desktop windows', (tester) async {
    await _pumpAt(tester, const HomeView(), 420);
    await _pumpAt(tester, const HomeView(), 800);
    await _pumpAt(tester, const HomeView(), 1280, height: 800);
    // Phone landscape: the narrow layout has less height than its cover.
    await _pumpAt(tester, const HomeView(), 560, height: 360);
  });

  testWidgets('desktop lyrics are the player lyrics, centered', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => showLyricsSignal.value = false);
    addTearDown(() => lyricsSuppressDimSignal.value = false);
    _publishTrack();
    showLyricsSignal.value = true;

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeView())),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    final lyrics = tester.widget<PlayerLyrics>(find.byType(PlayerLyrics));
    expect(lyrics.textAlign, TextAlign.center);
    // No lyrics in a widget test (no app context): the backdrop keeps its
    // bright look instead of dimming over an empty pane.
    expect(lyricsSuppressDimSignal.value, isTrue);
  });

  testWidgets('opening the lyrics does not write signals mid-build', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => showLyricsSignal.value = false);
    addTearDown(() => lyricsSuppressDimSignal.value = false);
    _publishTrack();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Mirrors the dim overlay, which watches the suppress signal.
              SignalBuilder(
                builder: (context) =>
                    SizedBox(height: lyricsSuppressDimSignal.value ? 1 : 0),
              ),
              const Expanded(child: HomeView()),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    showLyricsSignal.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(PlayerLyrics), findsOneWidget);
  });
}
