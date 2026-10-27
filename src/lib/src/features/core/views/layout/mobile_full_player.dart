import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/layout/mobile_cover_swipe.dart';
import 'package:yayma/src/features/core/views/layout/mobile_plate.dart';
import 'package:yayma/src/features/core/views/layout/player_lyrics.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_actions.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/playback/views/wave_view.dart';
import 'package:yayma/src/rust/api/models.dart';

final FlutterSignal<bool> mobileFullPlayerOpenSignal = signal(false);

class MobileFullPlayerOrigin {
  final Rect plateRect;
  final Rect coverRect;

  const MobileFullPlayerOrigin({
    required this.plateRect,
    required this.coverRect,
  });
}

final ValueNotifier<MobileFullPlayerOrigin?> mobileFullPlayerOrigin =
    ValueNotifier<MobileFullPlayerOrigin?>(null);
final ValueNotifier<double> mobileFullPlayerProgress = ValueNotifier<double>(0);

/// Live rect of the mini player plate.
///
/// The full player collapses into that plate, so it is re-read on every frame
/// instead of relying on the snapshot taken when the player was opened: the
/// plate moves on resize, rotation and while a track swipe animates.
final ValueNotifier<Rect?> mobileMiniPlayerPlateRect = ValueNotifier<Rect?>(
  null,
);

final MobileFullPlayerController mobileFullPlayerController =
    MobileFullPlayerController();

class MobileFullPlayerController {
  _MobileFullPlayerState? _state;
  double _progress = 0;
  bool? _pendingExpand;
  double _pendingVelocity = 0;

  double get progress => _progress;

  void reset() {
    _progress = 0;
    mobileFullPlayerProgress.value = 0;
    _pendingExpand = null;
    _pendingVelocity = 0;
  }

  void updateDrag(double value) {
    _progress = value.clamp(0.0, 1.0);
    mobileFullPlayerProgress.value = _progress;
    _state?._applyDragProgress(_progress);
  }

  void endDrag({required bool expand, double velocity = 0}) {
    final state = _state;
    if (state == null) {
      _pendingExpand = expand;
      _pendingVelocity = velocity;
      return;
    }
    state._settleFromDrag(expand: expand, velocity: velocity);
  }

  void _attach(_MobileFullPlayerState state) {
    _state = state;
    if (_progress <= 0) {
      state._controller.value = 0;
      unawaited(state._springTo(1, 0));
    } else {
      state._applyDragProgress(_progress);
    }
    final pending = _pendingExpand;
    final pendingVelocity = _pendingVelocity;
    _pendingExpand = null;
    _pendingVelocity = 0;
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(_state, state)) {
          state._settleFromDrag(expand: pending, velocity: pendingVelocity);
        }
      });
    }
  }

  void _detach(_MobileFullPlayerState state) {
    if (identical(_state, state)) {
      _state = null;
      _progress = 0;
      _pendingExpand = null;
      _pendingVelocity = 0;
    }
  }
}

class MobileFullPlayer extends StatefulWidget {
  final Rect plateRect;
  final Rect coverRect;
  final MobileFullPlayerController? controller;

  const MobileFullPlayer({
    required this.plateRect,
    required this.coverRect,
    this.controller,
    super.key,
  });

  @override
  State<MobileFullPlayer> createState() => _MobileFullPlayerState();
}

class _MobileFullPlayerState extends State<MobileFullPlayer>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _coverSwipe;

  /// The panel is rebuilt by both controllers: the expand / collapse progress
  /// and the horizontal offset of the cover.
  late final Listenable _animations;

  /// Owns the cover swipe state machine (direction, commit, held artwork).
  late final CoverSwipeController _swipe;

  /// Keeps the artwork in sync with playback: finishes a committed swipe once
  /// the new track arrives and slides the carousel when the track changes
  /// without a gesture (buttons, queue advance).
  late final EffectCleanup _swipeTrackChange;

  /// Keeps the neighbours in sync with playback so their artwork is always
  /// resolved, decoded and painted off-screen before it can slide in.
  late final EffectCleanup _neighborWarmup;
  String? _prevCoverUrl;
  String? _nextCoverUrl;

  bool _closing = false;
  bool _lyrics = false;

  /// 0 = cover, 1 = lyrics. Fades the artwork out instead of swapping the
  /// two layouts within a single frame.
  late final AnimationController _lyricsFade;

  void _toggleLyrics() {
    setState(() => _lyrics = !_lyrics);
    if (_lyrics) {
      _lyricsFade.forward();
    } else {
      _lyricsFade.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.addListener(_syncProgress);
    _lyricsFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: _lyrics ? 1 : 0,
    );
    _coverSwipe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      // The offset is unbounded, but the initial value has to be set
      // explicitly: it defaults to the lower bound, which is -infinity here.
      value: 0,
      lowerBound: double.negativeInfinity,
      upperBound: double.infinity,
    );
    _animations = Listenable.merge([_controller, _coverSwipe, _lyricsFade]);
    final initialState = playerStateSignal.value;
    _swipe = CoverSwipeController(
      animation: _coverSwipe,
      initialTrack: initialState?.currentTrack,
      initialIndex: initialState?.queueIndex,
      queue: () => queueTracksSignal().value ?? const [],
      travel: () => _swipeTravel(context),
      canAnimate: () => !_closing && _controller.value >= 0.95,
      isMounted: () => mounted,
      onNext: () => unawaited(PlaybackController.next()),
      onPrevious: () => unawaited(PlaybackController.previousTrack()),
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _swipeTrackChange = effect(() {
      final state = playerStateSignal.value;
      _swipe.onTrackChange(
        trackId: state?.currentTrack?.id,
        coverUrl: state?.currentTrack?.coverUrl,
      );
    });
    _neighborWarmup = effect(() {
      final prev = previousTrackSignal.value?.coverUrl;
      final next = nextTrackSignal.value?.coverUrl;
      if (prev == _prevCoverUrl && next == _nextCoverUrl) return;
      // The effect can run while a frame is being built; commit the new
      // neighbours once it is done so they start decoding right away.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (prev == _prevCoverUrl && next == _nextCoverUrl) return;
        setState(() {
          _prevCoverUrl = prev;
          _nextCoverUrl = next;
        });
      });
    });
    final dragController = widget.controller;
    if (dragController == null) {
      unawaited(_springTo(1, 0));
    } else {
      dragController._attach(this);
    }
  }

  @override
  void dispose() {
    mobileFullPlayerOpenSignal.value = false;
    mobileFullPlayerProgress.value = 0;
    widget.controller?._detach(this);
    _swipeTrackChange();
    _neighborWarmup();
    _swipe.dispose();
    _controller.dispose();
    _coverSwipe.dispose();
    _lyricsFade.dispose();
    super.dispose();
  }

  void _syncProgress() {
    mobileFullPlayerProgress.value = _controller.value;
  }

  Future<void> _revealMiniPlayer() async {
    _swipe.reset();
    mobileFullPlayerOpenSignal.value = false;
    await WidgetsBinding.instance.endOfFrame;
  }

  void _applyDragProgress(double value) {
    if (_closing) return;
    _controller
      ..stop()
      ..value = value.clamp(0.0, 1.0);
  }

  Future<void> _springTo(double target, double velocity) {
    final simulation = SpringSimulation(
      target == 0 ? kCoverSwipeCloseSpring : kCoverSwipeExpandSpring,
      _controller.value,
      target,
      velocity,
      snapToEnd: true,
    );
    return _controller.animateWith(simulation);
  }

  void _settleFromDrag({required bool expand, double velocity = 0}) {
    if (_closing) return;
    if (expand) {
      if (_controller.value >= 1 && velocity >= 0) return;
      unawaited(_springTo(1, velocity));
      return;
    }
    if (_lyrics) setState(() => _lyrics = false);
    _closing = true;
    unawaited(
      _springTo(0, velocity).then((_) {
        if (mounted) unawaited(_revealMiniPlayer());
      }),
    );
  }

  Future<void> _dismiss() async {
    if (_closing) return;
    if (_lyrics) setState(() => _lyrics = false);
    _closing = true;
    if (_controller.value <= 0) {
      await _revealMiniPlayer();
      return;
    }
    _controller.stop();
    await _springTo(0, 0);
    await _revealMiniPlayer();
  }

  /// Distance the cover travels to bring the neighbour in, matching the
  /// layout in [_buildAnimated].
  double _swipeTravel(BuildContext context) {
    final metrics = _FullPlayerMetrics.resolve(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    return metrics.coverRect.width + kCoverSwipeGap;
  }

  void _onCoverDragStart(DragStartDetails details) => _swipe.onDragStart();

  void _onCoverDragUpdate(DragUpdateDetails details) =>
      _swipe.onDragUpdate(details.primaryDelta ?? 0);

  void _onCoverDragEnd(DragEndDetails details) =>
      _swipe.onDragEnd(details.primaryVelocity ?? 0);

  void _onCoverDragCancel() => _swipe.onDragCancel();

  void _openAlbum(String albumId) {
    unawaited(
      _dismiss().then((_) {
        navigateTo(AppSection.album, albumId);
      }),
    );
  }

  void _openArtist(String artistId) {
    unawaited(
      _dismiss().then((_) {
        navigateTo(AppSection.artist, artistId);
      }),
    );
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (_closing) return;
    _controller.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_closing) return;
    final delta = details.primaryDelta ?? 0;
    final height = MediaQuery.sizeOf(context).height;
    _controller.value = (_controller.value - delta / (height * 0.55)).clamp(
      0.0,
      1.0,
    );
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_closing) return;
    final velocity = details.primaryVelocity ?? 0;
    final height = MediaQuery.sizeOf(context).height;
    final normalizedVelocity = -(velocity / (height * 0.55));
    final projected = (_controller.value + normalizedVelocity * 0.1).clamp(
      0.0,
      1.0,
    );
    _settleFromDrag(
      expand: projected >= 0.85 && velocity <= 700,
      velocity: normalizedVelocity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final metrics = _FullPlayerMetrics.resolve(size, padding);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_dismiss());
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        child: SignalBuilder(
          builder: (context) {
            final accent = accentColorSignal();
            // The stable variant: a track switch briefly reports `paused`,
            // and reacting to it would flicker the button and shrink the
            // cover mid-transition.
            final isPlaying = stablePlayingSignal();
            final navState = currentNavStateSignal.value;
            final surface = MiniPlateSurface(
              lyricsStyle:
                  navState.section == AppSection.home && showLyricsSignal.value,
              colorScheme: Theme.of(context).colorScheme,
            );
            // The neighbours of the playing track, kept mounted (invisible)
            // so their artwork is resolved and downloaded before the user
            // swipes. Refreshed after the transition, not during it.
            final prevCoverUrl = _prevCoverUrl;
            final nextCoverUrl = _nextCoverUrl;
            return TweenAnimationBuilder<double>(
              // The cover grows while the track plays and shrinks back while
              // it is paused, the same way the cover on the home screen does.
              tween: Tween<double>(
                end: isPlaying ? 1.0 : AppCoverMotion.largePausedScale,
              ),
              duration: AppCoverMotion.duration,
              curve: AppCoverMotion.curve,
              builder: (context, coverScale, child) => AnimatedBuilder(
                animation: _animations,
                child: child,
                builder: (context, child) => _buildAnimated(
                  context,
                  size: size,
                  metrics: metrics,
                  accent: accent,
                  surface: surface,
                  isPlaying: isPlaying,
                  coverScale: coverScale,
                  prevCoverUrl: prevCoverUrl,
                  nextCoverUrl: nextCoverUrl,
                  coverFade: _lyricsFade.value,
                  child: child!,
                ),
              ),
              child: _FullPlayerContent(
                animation: _controller,
                coverStart: widget.coverRect.bottom,
                coverEnd: metrics.coverRect.bottom,
                metrics: metrics,
                padding: padding,
                accent: accent,
                onClose: _dismiss,
                onToggleLyrics: _toggleLyrics,
                lyrics: _lyrics,
                lyricsFade: _lyricsFade,
                onOpenAlbum: _openAlbum,
                onOpenArtist: _openArtist,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAnimated(
    BuildContext context, {
    required Size size,
    required _FullPlayerMetrics metrics,
    required Color accent,
    required MiniPlateSurface surface,
    required bool isPlaying,
    required double coverScale,
    required String? prevCoverUrl,
    required String? nextCoverUrl,
    required double coverFade,
    required Widget child,
  }) {
    final panelT = _controller.value;
    final coverT = panelT;

    final plateRect = mobileMiniPlayerPlateRect.value ?? widget.plateRect;
    // The collapsed copy is laid out with the plate's content width, not with
    // the panel's: the panel is wider than the plate until the very last
    // frame, and a changing width would re-truncate the title right before
    // the real mini player takes over.
    final plateContentWidth = size.width - MiniPlateLayout.sideInset * 2;
    final closedCoverScale = Platform.isAndroid || isPlaying
        ? 1.0
        : AppCoverMotion.smallPausedScale;
    final closedCoverRect = _closing
        ? Rect.fromCenter(
            center: Offset(
              plateRect.left + MiniPlateLayout.coverCenterOffset,
              plateRect.center.dy,
            ),
            width: MiniPlateLayout.coverSize * closedCoverScale,
            height: MiniPlateLayout.coverSize * closedCoverScale,
          )
        : widget.coverRect;

    final screenRect = Offset.zero & size;
    final panelRect = Rect.lerp(plateRect, screenRect, panelT)!;
    // The cover shrinks while the track is paused. Only the open cover is
    // scaled: the collapsed one keeps the size of the mini plate, so the two
    // still match when they replace each other.
    final openCoverRect = Rect.fromCenter(
      center: metrics.coverRect.center,
      width: metrics.coverRect.width * coverScale,
      height: metrics.coverRect.height * coverScale,
    );
    // The cover grows with the panel: the panel clips its content, so a
    // faster growing cover would be cut off at the top.
    final coverRect = Rect.lerp(closedCoverRect, openCoverRect, coverT)!;
    // The neighbour covers keep a gap from the current one, so they do not
    // look glued together while one of them slides in.
    final neighborDistance = metrics.coverRect.width + kCoverSwipeGap;
    final panelRadius = ui.lerpDouble(AppRadius.xxxl, 0, panelT)!;
    final coverRadius = ui.lerpDouble(
      closedCoverRect.width / 2,
      AppRadius.xl,
      coverT,
    )!;

    // The panel background fades in over this window of the progress, and
    // the mini plate look fades out over the same one.
    const panelFadeWindow = 0.28;
    final panelOpacity = const Interval(
      0,
      panelFadeWindow,
      curve: Curves.easeOut,
    ).transform(panelT);
    final scrimOpacity =
        const Interval(0, 0.7, curve: Curves.easeOut).transform(panelT) * 0.5;

    final cs = Theme.of(context).colorScheme;
    final baseColor = Color.lerp(
      cs.surfaceContainerHighest,
      Colors.black,
      0.62,
    )!;
    final topColor = Color.alphaBlend(
      accent.withValues(alpha: 0.24),
      baseColor,
    );
    final bottomColor = Color.lerp(baseColor, Colors.black, 0.5)!;

    final miniAlpha = surface.alpha;
    final miniBlur = surface.blur;
    final miniColor = surface.color;
    final miniContentOpacity =
        1 - const Interval(0.16, 0.4, curve: Curves.easeOut).transform(panelT);
    final miniBottom = panelRect.bottom - plateRect.bottom;

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: scrimOpacity),
          ),
        ),
        Positioned.fromRect(
          rect: panelRect,
          child: _panelClip(
            panelRadius: panelRadius,
            panelT: panelT,
            child: Stack(
              children: [
                if (panelOpacity < 1)
                  Positioned.fill(
                    child: Opacity(
                      opacity: 1 - panelOpacity,
                      child: BackdropFilter(
                        enabled: blurEffectsEnabledSignal.value && miniBlur > 0,
                        filter: ui.ImageFilter.blur(
                          sigmaX: miniBlur,
                          sigmaY: miniBlur,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: miniColor.withValues(alpha: miniAlpha),
                            borderRadius: BorderRadius.circular(panelRadius),
                            border: Border.all(color: surface.borderColor),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  // Alpha lives in the gradient stops instead of an Opacity
                  // widget: same pixels, no full-screen saveLayer per frame.
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          topColor.withValues(alpha: panelOpacity),
                          baseColor.withValues(alpha: panelOpacity),
                          bottomColor.withValues(alpha: panelOpacity),
                        ],
                        stops: const [0, 0.45, 1],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: -panelRect.left,
                  top: -panelRect.top,
                  width: size.width,
                  height: size.height,
                  // The content repaints on every position tick; keep the
                  // full-screen panel gradient out of that repaint.
                  child: RepaintBoundary(
                    child: IgnorePointer(ignoring: panelT < 0.35, child: child),
                  ),
                ),
                if (miniContentOpacity > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: miniBottom,
                    height: 72,
                    child: Opacity(
                      opacity: miniContentOpacity,
                      child: Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.centerLeft,
                        children: [
                          Positioned(
                            left: MiniPlateLayout.titleInset,
                            width: MiniPlateLayout.titleWidth(
                              plateContentWidth,
                            ),
                            child: const MiniTrackTextInfo(),
                          ),
                          const Positioned(
                            right: 8,
                            top: 0,
                            bottom: 0,
                            child: Center(child: MiniPlayPauseButton()),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (coverFade < 1) ...[
                  // The neighbour covers stay mounted off-screen: that resolves,
                  // downloads and rasterises their artwork ahead of the swipe,
                  // so the cover that slides in is already there.
                  // They only become visible and interactive while they actually
                  // slide in, so the off-screen copies never paint or steal
                  // gestures.
                  for (final neighbour in [
                    (direction: -1, url: prevCoverUrl),
                    (direction: 1, url: nextCoverUrl),
                  ])
                    _buildCover(
                      context,
                      panelRect,
                      openCoverRect,
                      coverRadius,
                      panelT,
                      metrics.coverRect.width,
                      dx:
                          _coverSwipe.value +
                          neighbour.direction * neighborDistance,
                      coverUrl:
                          _swipe.direction == neighbour.direction &&
                              _swipe.canCommit
                          ? _swipe.incomingUrl
                          : neighbour.url,
                      opacity:
                          _swipe.direction == neighbour.direction &&
                              _swipe.canCommit
                          ? 1 - coverFade
                          : 0,
                      interactive:
                          coverFade == 0 &&
                          _swipe.direction == neighbour.direction &&
                          _swipe.canCommit,
                    ),
                  _buildCover(
                    context,
                    panelRect,
                    coverRect,
                    coverRadius,
                    panelT,
                    metrics.coverRect.width,
                    dx: _coverSwipe.value,
                    coverUrl: _swipe.holdUrl,
                    opacity: 1 - coverFade,
                    scale: 1 - 0.06 * coverFade,
                    interactive: coverFade == 0,
                    onTap: () {
                      final albumId = trackMetadataSignal().albumId;
                      if (albumId != null) _openAlbum(albumId);
                    },
                  ),
                ],
                if (miniContentOpacity > 0)
                  Positioned(
                    left: MiniPlateLayout.sideInset,
                    width: MiniPlateLayout.progressWidth(plateContentWidth),
                    bottom: miniBottom,
                    height: 16,
                    child: Opacity(
                      opacity: miniContentOpacity,
                      child: const MiniProgressSlider(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The panel only needs a clip while it grows over the screen: when open it
  /// is the whole screen and the rounded corners are gone, so the clip layer
  /// would be pure per-frame cost.
  Widget _panelClip({
    required double panelRadius,
    required double panelT,
    required Widget child,
  }) {
    if (panelT >= 1) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(panelRadius),
      child: child,
    );
  }

  Widget _buildCover(
    BuildContext context,
    Rect panelRect,
    Rect coverRect,
    double radius,
    double progress,
    double side, {
    double dx = 0,
    String? coverUrl,
    VoidCallback? onTap,
    double opacity = 1,
    double scale = 1,
    bool interactive = true,
  }) {
    // The shadow is the most expensive thing to paint here, and it only
    // changes when the panel animates or the artwork loads: keep it in its
    // own layer instead of re-blurring it per frame.
    final Widget artwork = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35 * progress),
              blurRadius: 12 + 24 * progress,
              offset: Offset(0, 8 * progress),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SignalBuilder(
            builder: (context) {
              final rawUrl = coverUrl ?? trackMetadataSignal().coverUrl;
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final targetPx = (side * dpr).round().clamp(0, 800);
              final lowResUrl = rawUrl == null
                  ? null
                  : resolveCoverUrl(rawUrl, (48 * dpr).round());
              final highResUrl = rawUrl == null
                  ? null
                  : resolveCoverUrl(rawUrl, targetPx);

              final placeholder = lowResUrl == null
                  ? CoverPlaceholder(size: side, icon: Icons.music_note)
                  : RustCachedImage(
                      imageUrl: lowResUrl,
                      width: side,
                      height: side,
                      cacheWidth: (48 * dpr).round(),
                      cacheHeight: (48 * dpr).round(),
                    );

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Follow the finger from where it went down: with the default
                // the cover only starts moving after the drag is accepted,
                // which reads as lag on the first few pixels.
                dragStartBehavior: DragStartBehavior.down,
                onTap: onTap,
                onHorizontalDragStart: _onCoverDragStart,
                onHorizontalDragUpdate: _onCoverDragUpdate,
                onHorizontalDragEnd: _onCoverDragEnd,
                onHorizontalDragCancel: _onCoverDragCancel,
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox.square(
                    dimension: side,
                    child: RustCachedImage(
                      imageUrl: highResUrl,
                      width: side,
                      height: side,
                      cacheWidth: targetPx,
                      cacheHeight: targetPx,
                      placeholder: placeholder,
                      errorWidget: placeholder,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    return Positioned(
      // Only the resting layout here: the swipe / slide offset goes through
      // the transform below, so moving the carousel is compositing only.
      // A changing Positioned rect would relayout the cover and invalidate
      // its cached raster (the large blurred shadow) on every frame.
      left: coverRect.left - panelRect.left,
      top: coverRect.top - panelRect.top,
      width: coverRect.width,
      height: coverRect.height,
      // Pre-warmed neighbours stay laid out off-screen but must not intercept
      // taps or drags next to the visible cover. Zero opacity still builds and
      // decodes the artwork, just without painting it.
      child: IgnorePointer(
        ignoring: !interactive,
        child: ExcludeSemantics(
          excluding: !interactive,
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(
              scale: scale,
              child: opacity >= 1
                  ? artwork
                  : Opacity(opacity: opacity, child: artwork),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullPlayerMetrics {
  final Rect coverRect;
  final double coverSpace;
  final double headerHeight;
  final double infoHeight;
  final double progressHeight;
  final double controlsHeight;
  final double actionsHeight;
  final double bottomGap;
  final double sectionWidth;
  final double horizontalPadding;

  const _FullPlayerMetrics({
    required this.coverRect,
    required this.coverSpace,
    required this.headerHeight,
    required this.infoHeight,
    required this.progressHeight,
    required this.controlsHeight,
    required this.actionsHeight,
    required this.bottomGap,
    required this.sectionWidth,
    required this.horizontalPadding,
  });

  factory _FullPlayerMetrics.resolve(Size size, EdgeInsets padding) {
    final compact = size.height < 700;
    final headerHeight = compact ? 48.0 : 56.0;
    final infoHeight = compact ? 68.0 : 78.0;
    const progressHeight = 68.0;
    final controlsHeight = compact ? 76.0 : 88.0;
    final actionsHeight = compact ? 52.0 : 58.0;
    final bottomGap = compact ? 4.0 : 8.0;
    final horizontalPadding = size.width < 420 ? 20.0 : 28.0;
    final sectionWidth = math.min<double>(
      size.width - horizontalPadding * 2,
      520,
    );
    final safeHeight = math.max<double>(
      0,
      size.height - padding.top - padding.bottom,
    );
    final fixedHeight =
        headerHeight +
        infoHeight +
        progressHeight +
        controlsHeight +
        actionsHeight +
        bottomGap;
    // The column spends these two gaps around the cover, so they come out of
    // the cover budget — otherwise the column overflows by exactly their sum.
    const coverGap = 12.0;
    const coverTopGap = 12.0;
    final availableForCover = math.max<double>(
      0,
      safeHeight - fixedHeight - coverGap - coverTopGap,
    );
    final coverSide = math.max<double>(
      1,
      math.min<double>(sectionWidth, availableForCover),
    );
    // The cover sits right under the header and the title right under the
    // cover; the height that is left over goes between the title and the
    // progress bar, so the controls stay anchored to the bottom.
    final coverTop = padding.top + headerHeight + coverTopGap;

    return _FullPlayerMetrics(
      coverRect: Rect.fromLTWH(
        horizontalPadding,
        coverTop,
        coverSide,
        coverSide,
      ),
      coverSpace: coverSide + coverGap + coverTopGap,
      headerHeight: headerHeight,
      infoHeight: infoHeight,
      progressHeight: progressHeight,
      controlsHeight: controlsHeight,
      actionsHeight: actionsHeight,
      bottomGap: bottomGap,
      sectionWidth: sectionWidth,
      horizontalPadding: horizontalPadding,
    );
  }
}

class _Reveal extends StatelessWidget {
  final Animation<double> animation;
  final Interval interval;
  final double offset;
  final Widget child;

  const _Reveal({
    required this.animation,
    required this.interval,
    required this.offset,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final value = interval.transform(animation.value.clamp(0.0, 1.0));
        final child_ = Transform.translate(
          offset: Offset(0, (1 - value) * offset),
          child: child,
        );
        // Fully revealed sections need no opacity layer at all.
        if (value >= 1) return child_;
        return Opacity(opacity: value, child: child_);
      },
    );
  }
}

class _CoverClearReveal extends StatelessWidget {
  final Animation<double> animation;
  final double coverStart;
  final double coverEnd;
  final double sectionTop;
  final double offset;
  final Widget child;

  const _CoverClearReveal({
    required this.animation,
    required this.coverStart,
    required this.coverEnd,
    required this.sectionTop,
    required this.offset,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final travel = coverEnd - coverStart;
    final rawStart = travel == 0 ? 1.0 : (sectionTop - coverStart) / travel;
    final start = rawStart.clamp(0.0, 0.96);
    final end = (start + 0.15).clamp(0.0, 1.0);

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = animation.value.clamp(0.0, 1.0);
        final value = Curves.easeOutCubic.transform(
          ((t - start) / (end - start)).clamp(0.0, 1.0),
        );
        final child_ = Transform.translate(
          offset: Offset(0, (1 - value) * offset),
          child: child,
        );
        // Fully revealed sections need no opacity layer at all.
        if (value >= 1) return child_;
        return Opacity(opacity: value, child: child_);
      },
    );
  }
}

class _FullPlayerContent extends StatelessWidget {
  final Animation<double> animation;
  final double coverStart;
  final double coverEnd;
  final _FullPlayerMetrics metrics;
  final EdgeInsets padding;
  final Color accent;
  final VoidCallback onClose;
  final VoidCallback onToggleLyrics;
  final bool lyrics;

  /// 0 = cover, 1 = lyrics. Keeps the text fading out while the artwork
  /// fades back in. Listened to inside, because this widget is cached as the
  /// per-frame builder's `child` and would otherwise keep a stale value.
  final Animation<double> lyricsFade;
  final ValueChanged<String> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;

  const _FullPlayerContent({
    required this.animation,
    required this.coverStart,
    required this.coverEnd,
    required this.metrics,
    required this.padding,
    required this.accent,
    required this.onClose,
    required this.onToggleLyrics,
    required this.lyrics,
    required this.lyricsFade,
    required this.onOpenAlbum,
    required this.onOpenArtist,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: EdgeInsets.only(top: padding.top, bottom: padding.bottom),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The height the cover block leaves unused in cover mode. The
            // lyrics pane grows into it, so both modes still share one layout
            // and only the hero area changes size while they cross-fade.
            final fixed =
                metrics.headerHeight +
                metrics.coverSpace +
                metrics.infoHeight +
                metrics.progressHeight +
                metrics.controlsHeight +
                metrics.actionsHeight +
                metrics.bottomGap;
            final spare = math.max(0, constraints.maxHeight - fixed);
            return AnimatedBuilder(
              animation: lyricsFade,
              builder: (context, _) {
                final coverFade = lyricsFade.value;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Reveal(
                      animation: animation,
                      interval: const Interval(
                        0.18,
                        0.55,
                        curve: Curves.easeOutCubic,
                      ),
                      offset: 10,
                      child: SizedBox(
                        height: metrics.headerHeight,
                        child: _FullPlayerHeader(
                          onClose: onClose,
                          onToggleLyrics: onToggleLyrics,
                          lyrics: lyrics,
                          accent: accent,
                        ),
                      ),
                    ),
                    SizedBox(
                      height:
                          metrics.coverSpace +
                          metrics.infoHeight +
                          spare * coverFade,
                      child: Stack(
                        children: [
                          if (coverFade < 1)
                            Opacity(
                              opacity: 1 - coverFade,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(height: metrics.coverSpace),
                                  SizedBox(
                                    height: metrics.infoHeight,
                                    child: _CoverClearReveal(
                                      animation: animation,
                                      coverStart: coverStart,
                                      coverEnd: coverEnd,
                                      sectionTop:
                                          padding.top +
                                          metrics.headerHeight +
                                          metrics.coverSpace,
                                      offset: 16,
                                      child: _ContentColumn(
                                        width: metrics.sectionWidth,
                                        leftPadding: metrics.horizontalPadding,
                                        child: _FullPlayerTrackInfo(
                                          onOpenAlbum: onOpenAlbum,
                                          onOpenArtist: onOpenArtist,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (coverFade > 0)
                            Positioned.fill(
                              child: IgnorePointer(
                                ignoring: !lyrics,
                                child: Opacity(
                                  opacity: coverFade,
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: metrics.horizontalPadding,
                                    ),
                                    child: _Reveal(
                                      animation: animation,
                                      interval: const Interval(
                                        0.18,
                                        0.55,
                                        curve: Curves.easeOutCubic,
                                      ),
                                      offset: 10,
                                      child: SignalBuilder(
                                        builder: (context) {
                                          final trackId =
                                              trackMetadataSignal().id;
                                          if (trackId == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return PlayerLyrics(
                                            key: ValueKey(trackId),
                                            trackId: trackId,
                                            accent: accent,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _Reveal(
                      animation: animation,
                      interval: const Interval(
                        0.36,
                        0.78,
                        curve: Curves.easeOutCubic,
                      ),
                      offset: 14,
                      child: SizedBox(
                        height: metrics.progressHeight,
                        child: _ContentColumn(
                          width: metrics.sectionWidth,
                          leftPadding: metrics.horizontalPadding,
                          child: _FullPlayerProgress(
                            accent: accent,
                            width: metrics.sectionWidth,
                          ),
                        ),
                      ),
                    ),
                    _Reveal(
                      animation: animation,
                      interval: const Interval(
                        0.44,
                        0.88,
                        curve: Curves.easeOutCubic,
                      ),
                      offset: 18,
                      child: SizedBox(
                        height: metrics.controlsHeight,
                        child: _ContentColumn(
                          width: metrics.sectionWidth,
                          leftPadding: metrics.horizontalPadding,
                          child: _FullPlayerControls(accent: accent),
                        ),
                      ),
                    ),
                    _Reveal(
                      animation: animation,
                      interval: const Interval(
                        0.52,
                        0.96,
                        curve: Curves.easeOutCubic,
                      ),
                      offset: 16,
                      child: SizedBox(
                        height: metrics.actionsHeight,
                        child: _ContentColumn(
                          width: metrics.sectionWidth,
                          leftPadding: metrics.horizontalPadding,
                          child: _FullPlayerActions(accent: accent),
                        ),
                      ),
                    ),
                    SizedBox(height: metrics.bottomGap),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _FullPlayerHeader extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback onToggleLyrics;
  final bool lyrics;
  final Color accent;

  const _FullPlayerHeader({
    required this.onClose,
    required this.onToggleLyrics,
    required this.lyrics,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            tooltip: 'Свернуть',
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 28,
              color: onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              'Сейчас играет',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
              ),
            ),
          ),
          SignalBuilder(
            builder: (context) {
              final hasTrack = trackMetadataSignal().id != null;
              return SizedBox(
                width: 48,
                child: IconButton(
                  onPressed: hasTrack ? onToggleLyrics : null,
                  tooltip: 'Текст песни',
                  icon: Icon(
                    Icons.lyrics_rounded,
                    size: 24,
                    color: lyrics ? accent : onSurfaceVariant,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FullPlayerWaveButton extends StatelessWidget {
  final Color accent;

  const _FullPlayerWaveButton({required this.accent});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isWaveActive = currentWaveSeedsSignal().isNotEmpty;
        return IconButton(
          iconSize: 24,
          icon: Icon(
            Icons.tune_rounded,
            color: isWaveActive
                ? accent
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          tooltip: 'Настройки волны',
          onPressed: () => unawaited(showWaveSettingsSheet(context)),
        );
      },
    );
  }
}

/// Places its child in the player's content column: the same left margin and
/// the same width as the cover, so the artwork, the title, the progress bar
/// and the buttons all line up.
class _ContentColumn extends StatelessWidget {
  final double width;
  final double leftPadding;
  final Widget child;

  const _ContentColumn({
    required this.width,
    required this.leftPadding,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: leftPadding),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: width, child: child),
      ),
    );
  }
}

class _FullPlayerTrackInfo extends StatelessWidget {
  final ValueChanged<String> onOpenAlbum;
  final ValueChanged<String> onOpenArtist;

  const _FullPlayerTrackInfo({
    required this.onOpenAlbum,
    required this.onOpenArtist,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final meta = trackMetadataSignal();
        final cs = Theme.of(context).colorScheme;
        final compact = MediaQuery.sizeOf(context).height < 700;

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          // Without this the column centres its children and the artist names
          // end up in the middle instead of under the title.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: GestureDetector(
                          onTap: meta.albumId != null
                              ? () => onOpenAlbum(meta.albumId!)
                              : null,
                          child: _MarqueeTitle(
                            text: meta.title,
                            version: meta.version,
                            versionFontSize: compact ? 13 : 15,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: compact ? 17 : 20,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.6,
                              height: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (meta.id != null)
                  IconButton(
                    onPressed: () => unawaited(
                      TrackContextActions(
                        trackId: meta.id!,
                        title: meta.title,
                        version: meta.version,
                        artists: meta.artists,
                        albumId: meta.albumId,
                        coverUrl: meta.coverUrl,
                      ).showSheet(context),
                    ),
                    icon: const Icon(Icons.more_vert_rounded),
                    iconSize: 22,
                    color: cs.onSurfaceVariant,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    tooltip: 'Действия',
                  ),
              ],
            ),
            const SizedBox(height: 4),
            ArtistNamesWidget(
              artists: meta.artists,
              fontSize: compact ? 14 : 15,
              color: cs.onSurface.withValues(alpha: 0.55),
              maxLines: 1,
              onArtistTap: onOpenArtist,
            ),
          ],
        );
      },
    );
  }
}

/// Single-line title that scrolls horizontally when it does not fit the
/// available width, with a short pause at both ends. Static (clipped) when
/// it fits or when animations are disabled.
class _MarqueeTitle extends StatefulWidget {
  final String text;
  final String? version;
  final double? versionFontSize;
  final TextStyle style;

  const _MarqueeTitle({
    required this.text,
    required this.style,
    this.version,
    this.versionFontSize,
  });

  @override
  State<_MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<_MarqueeTitle>
    with SingleTickerProviderStateMixin {
  static const double _gap = 48;
  static const double _speed = 40;

  late final AnimationController _controller = AnimationController(vsync: this);
  late final CurvedAnimation _position = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.08, 0.88),
  );

  double _distance = 0;

  @override
  void dispose() {
    _position.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation({required bool scrolling, required double distance}) {
    if (!scrolling) {
      if (_controller.isAnimating) _controller.stop();
      _distance = 0;
      return;
    }
    if (_distance == distance && _controller.isAnimating) return;

    _distance = distance;
    final travelMs = distance / _speed * 1000;
    _controller.duration = Duration(
      milliseconds: (travelMs / 0.8).round().clamp(4000, 60000),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _distance == 0) return;
      _controller
        ..value = 0
        ..repeat();
    });
  }

  @override
  Widget build(BuildContext context) {
    final span = trackTitleSpan(
      context,
      title: widget.text,
      version: widget.version,
      versionFontSize: widget.versionFontSize,
      style: widget.style,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: span,
          textDirection: Directionality.of(context),
          maxLines: 1,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final textWidth = painter.width;
        final reduceMotion = MediaQuery.of(context).disableAnimations;
        final overflow =
            constraints.hasBoundedWidth &&
            textWidth > constraints.maxWidth &&
            !reduceMotion;

        _syncAnimation(scrolling: overflow, distance: textWidth + _gap);

        final text = Text.rich(
          span,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        );

        if (!overflow) {
          return Align(alignment: Alignment.centerLeft, child: text);
        }

        // The marquee animates on every frame. Without a repaint boundary
        // here the moving Transform would repaint its whole ancestry (panel
        // gradients, buttons, slider), not just the text.
        return RepaintBoundary(
          child: ClipRect(
            child: SizedBox(
              width: constraints.maxWidth,
              height: painter.height,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: AnimatedBuilder(
                  animation: _position,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(-_position.value * _distance, 0),
                    child: child,
                  ),
                  child: RepaintBoundary(
                    // The text itself never changes, so let it scroll as a
                    // cached layer.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        text,
                        const SizedBox(width: _gap),
                        text,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FullPlayerProgress extends StatelessWidget {
  final Color accent;
  final double width;

  const _FullPlayerProgress({required this.accent, required this.width});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: width,
        child: CommonProgressSlider(accentColor: accent, maxWidth: width),
      ),
    );
  }
}

class _FullPlayerControls extends StatelessWidget {
  final Color accent;

  const _FullPlayerControls({required this.accent});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isPlaying = stablePlayingSignal();
        final showBuffering = showBufferingIndicatorSignal.value;
        final meta = trackMetadataSignal();
        final trackId = meta.id;
        final isLiked = isLikedSignal();
        final isDisliked = isDislikedSignal();
        final cs = Theme.of(context).colorScheme;
        final onSurface = cs.onSurface;
        final onSurfaceVariant = cs.onSurfaceVariant;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 24,
              icon: Icon(
                isDisliked ? Icons.heart_broken : Icons.heart_broken_outlined,
                color: isDisliked ? Colors.blueGrey : onSurfaceVariant,
              ),
              onPressed: trackId != null
                  ? () => unawaited(
                      PlaybackController.toggleDislike(trackId: trackId),
                    )
                  : null,
            ),
            IconButton(
              iconSize: 38,
              icon: Icon(Icons.skip_previous_rounded, color: onSurface),
              onPressed: PlaybackController.prev,
            ),
            IconButton(
              iconSize: 76,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 76, minHeight: 76),
              icon: showBuffering
                  ? M3ECircularWavyProgressIndicator(
                      strokeWidth: 3,
                      color: accent,
                    )
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: animation,
                            child: child,
                          ),
                        );
                      },
                      child: Icon(
                        isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                        key: ValueKey<bool>(isPlaying),
                        color: onSurface,
                      ),
                    ),
              onPressed: PlaybackController.togglePlay,
            ),
            IconButton(
              iconSize: 38,
              icon: Icon(Icons.skip_next_rounded, color: onSurface),
              onPressed: PlaybackController.next,
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: AnimatedLikeButton(
                  isLiked: isLiked,
                  size: 24,
                  likedColor: accent,
                  onTap: trackId != null
                      ? () => unawaited(
                          PlaybackController.toggleLike(trackId: trackId),
                        )
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FullPlayerActions extends StatelessWidget {
  final Color accent;

  const _FullPlayerActions({required this.accent});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isShuffled = isShuffledSignal();
        final repeatMode = repeatModeSignal();
        final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;

        var repeatIcon = Icons.repeat_rounded;
        if (repeatMode == RepeatModeDto.single) {
          repeatIcon = Icons.repeat_one_rounded;
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 24,
              icon: Icon(
                Icons.shuffle_rounded,
                color: isShuffled ? accent : onSurfaceVariant,
              ),
              onPressed: PlaybackController.toggleShuffle,
            ),
            _FullPlayerWaveButton(accent: accent),
            IconButton(
              iconSize: 24,
              icon: Icon(
                repeatIcon,
                color: repeatMode != RepeatModeDto.none
                    ? accent
                    : onSurfaceVariant,
              ),
              onPressed: PlaybackController.toggleRepeat,
            ),
          ],
        );
      },
    );
  }
}
