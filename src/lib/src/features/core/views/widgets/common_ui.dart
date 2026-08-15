import 'dart:async';
import 'dart:ui' as ui;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

String formatDuration(int ms) {
  final d = Duration(milliseconds: ms);
  return "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";
}

class CommonLoadingWidget extends StatelessWidget {
  const CommonLoadingWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: M3ECircularWavyProgressIndicator(
        size: 56,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

class CommonErrorWidget extends StatelessWidget {
  final String error;
  const CommonErrorWidget({required this.error, super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Ошибка: $error',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

class CommonSectionTitle extends StatelessWidget {
  final String title;
  final EdgeInsets? padding;

  const CommonSectionTitle({
    required this.title,
    super.key,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final isNarrow = context.isNarrow;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    final effectivePadding =
        padding ??
        EdgeInsets.symmetric(
          vertical: 24,
          horizontal: context.horizontalPadding,
        );

    return Padding(
      padding: effectivePadding,
      child: Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: isNarrow ? 22 : 28,
          fontWeight: FontWeight.w800,
          color: onSurface,
          letterSpacing: -0.5,
          height: 1.1,
        ),
      ),
    );
  }
}

class CommonDetailHeader extends StatelessWidget {
  final String type;
  final String title;
  final List<TrackArtistDto>? artists;
  final String? subtitle;
  final String? secondarySubtitle;
  final String? coverUrl;
  final double coverSize;
  final bool isCircle;
  final List<Widget>? actions;
  final Widget? titleTrailing;

  const CommonDetailHeader({
    required this.type,
    required this.title,
    super.key,
    this.artists,
    this.subtitle,
    this.secondarySubtitle,
    this.coverUrl,
    this.coverSize = 250,
    this.isCircle = false,
    this.actions,
    this.titleTrailing,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final onSurfaceVariant = scheme.onSurfaceVariant;

    final actualCoverSize = isNarrow
        ? (screenWidth - 80).clamp(150.0, 200.0)
        : coverSize;

    final titleWidget = Text(
      title,
      textAlign: isNarrow ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.displayMedium?.copyWith(
        fontSize: isNarrow ? 32 : 48,
        fontWeight: FontWeight.w900,
        color: onSurface,
        height: 1.05,
        letterSpacing: -1.5,
      ),
    );

    final content = Column(
      crossAxisAlignment: isNarrow
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          type.toUpperCase(),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: onSurface.withValues(alpha: 0.55),
            letterSpacing: 2,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        if (titleTrailing != null) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: titleWidget),
              const SizedBox(width: 4),
              Transform.translate(
                offset: const Offset(0, 7),
                child: titleTrailing,
              ),
            ],
          ),
        ] else ...[
          titleWidget,
        ],
        if (artists != null) ...[
          const SizedBox(height: 12),
          ArtistNamesWidget(
            artists: artists!,
            fontSize: isNarrow ? 18 : 24,
            color: onSurfaceVariant,
            alignment: isNarrow ? WrapAlignment.center : WrapAlignment.start,
          ),
        ] else if (subtitle != null) ...[
          const SizedBox(height: 12),
          Text(
            subtitle!,
            textAlign: isNarrow ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: isNarrow ? 18 : 24,
              color: onSurfaceVariant,
            ),
          ),
        ],
        if (secondarySubtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            secondarySubtitle!,
            textAlign: isNarrow ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              color: onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
        if (actions != null) ...[
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: isNarrow ? WrapAlignment.center : WrapAlignment.start,
            children: actions!,
          ),
        ],
      ],
    );

    return Padding(
      padding: EdgeInsets.all(isNarrow ? 20 : 40),
      child: isNarrow
          ? Column(
              children: [
                TrackCover(
                  url: coverUrl,
                  size: actualCoverSize,
                  borderRadius: 16,
                  isCircle: isCircle,
                  canExpand: true,
                  heroTag: coverUrl,
                ),
                const SizedBox(height: 24),
                content,
              ],
            )
          : Row(
              crossAxisAlignment: isCircle
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.end,
              children: [
                TrackCover(
                  url: coverUrl,
                  size: actualCoverSize,
                  borderRadius: 16,
                  isCircle: isCircle,
                  canExpand: true,
                  heroTag: coverUrl,
                ),
                const SizedBox(width: 40),
                Expanded(child: content),
              ],
            ),
    );
  }
}

class CommonVolumeSlider extends StatefulWidget {
  final double width;
  final Color? activeColor;
  const CommonVolumeSlider({
    super.key,
    this.width = 120,
    this.activeColor,
  });

  @override
  State<CommonVolumeSlider> createState() => _CommonVolumeSliderState();
}

class _CommonVolumeSliderState extends State<CommonVolumeSlider> {
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    final activeColor =
        widget.activeColor ?? Theme.of(context).colorScheme.primary;
    return SignalBuilder(
      builder: (context) {
        final volume = playerVolumeSignal().toDouble();
        final displayVolume = _dragVolume ?? volume;

        return SizedBox(
          width: widget.width,
          child: M3ESlider(
            value: displayVolume.clamp(0, 100),
            max: 100,
            decoration: expressSliderDecoration(
              activeColor: activeColor,
              inactiveColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.15),
            ),
            onChanged: (val) {
              setState(() => _dragVolume = val);
              unawaited(PlaybackController.changeVolume(val.toInt()));
            },
            onChangeEnd: (_) {
              setState(() => _dragVolume = null);
            },
          ),
        );
      },
    );
  }
}

class AudioDeviceButton extends StatefulWidget {
  final double iconSize;
  const AudioDeviceButton({super.key, this.iconSize = 18});

  @override
  State<AudioDeviceButton> createState() => _AudioDeviceButtonState();
}

class _AudioDeviceButtonState extends State<AudioDeviceButton> {
  bool _devicesLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevices());
  }

  Future<void> _loadDevices() async {
    await refreshAudioDevices();
    if (mounted) {
      setState(() => _devicesLoaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final devices = audioDevicesSignal.value;
        final selectedDevice = selectedAudioDeviceSignal.value;
        final accentColor = accentColorSignal.value;

        final items = [
          AppContextMenuItem<String>(
            value: '',
            label: 'По умолчанию',
            icon: Icons.computer_rounded,
            isSelected: selectedDevice == null,
            color: selectedDevice == null ? accentColor : null,
          ),
          ...devices.map(
            (device) => AppContextMenuItem<String>(
              value: device,
              label: device,
              icon: Icons.speaker_rounded,
              isSelected: device == selectedDevice,
              color: device == selectedDevice ? accentColor : null,
            ),
          ),
        ];

        return AppContextMenu<String>(
          onOpen: () {
            if (!_devicesLoaded) {
              unawaited(_loadDevices());
            }
          },
          onSelected: (value) {
            unawaited(setAudioDevice(value));
          },
          items: items,
          child: IconButton(
            icon: Icon(
              Icons.speaker_group_rounded,
              size: widget.iconSize,
              color: selectedDevice != null
                  ? accentColor
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            tooltip: selectedDevice ?? 'Устройство вывода',
            onPressed: null, // AppContextMenu handles clicks
          ),
        );
      },
    );
  }
}

typedef DataBuilder<T> = Widget Function(BuildContext context, T data);

class CommonAsyncView<T> extends StatelessWidget {
  final AsyncState<T> state;
  final DataBuilder<T> builder;
  final Widget? loading;
  final Widget Function(String error)? error;
  final Widget? empty;
  final bool Function(T data)? isEmpty;

  const CommonAsyncView({
    required this.state,
    required this.builder,
    super.key,
    this.loading,
    this.error,
    this.empty,
    this.isEmpty,
  });

  @override
  Widget build(BuildContext context) {
    return state.map(
      data: (data) {
        if (isEmpty != null && isEmpty!(data)) {
          return empty ?? const Center(child: Text('Пусто'));
        }
        return builder(context, data);
      },
      loading: () => loading ?? const CommonLoadingWidget(),
      error: (Object e, _) => error != null
          ? error!(e.toString())
          : CommonErrorWidget(error: e.toString()),
    );
  }
}

class CommonDetailSliverLayout extends StatelessWidget {
  final Widget header;
  final List<Widget> slivers;
  final ScrollController? controller;

  const CommonDetailSliverLayout({
    required this.header,
    required this.slivers,
    super.key,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: controller,
      slivers: [
        SliverToBoxAdapter(child: header),
        ...slivers,
        const SliverToBoxAdapter(child: SizedBox(height: 140)),
      ],
    );
  }
}

class CommonProgressSlider extends StatefulWidget {
  final Color? accentColor;
  final double maxWidth;
  final bool compact;
  const CommonProgressSlider({
    this.accentColor,
    super.key,
    this.maxWidth = double.infinity,
    this.compact = false,
  });

  @override
  State<CommonProgressSlider> createState() => _CommonProgressSliderState();
}

class _CommonProgressSliderState extends State<CommonProgressSlider> {
  double? _dragValue;
  Timer? _dragEndTimer;

  @override
  void dispose() {
    _dragEndTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: SignalBuilder(
        builder: (context) {
          final progress = trackProgressSignal();
          final dur = progress.durationMs;
          final displayPosition = _dragValue ?? progress.positionMs;
          final trackHeight = widget.compact ? 4.0 : 6.0;
          final thumbRadius = widget.compact ? 4.0 : 6.0;
          final fontSize = widget.compact ? 11.0 : 12.0;
          final accentColor = widget.accentColor ?? accentColorSignal.value;
          final onSurfaceVariant = Theme.of(
            context,
          ).colorScheme.onSurfaceVariant;

          return widget.compact
              ? Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        formatDuration(displayPosition.toInt()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: onSurfaceVariant,
                          fontSize: fontSize,
                          fontWeight: FontWeight.bold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: ClipRect(
                        child: SizedBox(
                          height: 28,
                          child: M3ESlider(
                            value: displayPosition.clamp(
                              0,
                              dur > 0 ? dur : 1.0,
                            ),
                            max: dur > 0 ? dur : 1.0,
                            decoration: expressSliderDecoration(
                              activeColor: accentColor,
                              trackHeight: trackHeight,
                              thumbWidth: thumbRadius,
                              thumbHeight: thumbRadius * 3.5,
                              inactiveColor: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.15),
                            ),
                            onChangeStart: (val) {
                              setState(() => _dragValue = val);
                            },
                            onChanged: (val) {
                              setState(() => _dragValue = val);
                            },
                            onChangeEnd: (val) {
                              setState(() => _dragValue = val);
                              _dragEndTimer?.cancel();
                              _dragEndTimer = Timer(
                                const Duration(milliseconds: 500),
                                () {
                                  if (mounted) {
                                    setState(() => _dragValue = null);
                                  }
                                },
                              );
                              unawaited(
                                PlaybackController.seekTo(
                                  Duration(milliseconds: val.toInt()),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        formatDuration(dur.toInt()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: onSurfaceVariant,
                          fontSize: fontSize,
                          fontWeight: FontWeight.bold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    M3ESlider(
                      value: displayPosition.clamp(0.0, dur),
                      max: dur,
                      decoration: expressSliderDecoration(
                        activeColor: accentColor,
                        trackHeight: trackHeight,
                        thumbWidth: thumbRadius * 1.4,
                        thumbHeight: thumbRadius * 4,
                        inactiveColor: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.15),
                      ),
                      onChangeStart: (val) {
                        setState(() => _dragValue = val);
                      },
                      onChanged: (val) {
                        setState(() => _dragValue = val);
                      },
                      onChangeEnd: (val) {
                        setState(() => _dragValue = val);
                        _dragEndTimer?.cancel();
                        _dragEndTimer = Timer(
                          const Duration(milliseconds: 500),
                          () {
                            if (mounted) {
                              setState(() => _dragValue = null);
                            }
                          },
                        );
                        unawaited(
                          PlaybackController.seekTo(
                            Duration(milliseconds: val.toInt()),
                          ),
                        );
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          formatDuration(displayPosition.toInt()),
                          style: TextStyle(
                            color: onSurfaceVariant,
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          formatDuration(dur.toInt()),
                          style: TextStyle(
                            color: onSurfaceVariant,
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                );
        },
      ),
    );
  }
}

M3ESliderDecoration expressSliderDecoration({
  required Color activeColor,
  required Color inactiveColor,
  double trackHeight = 4,
  double thumbWidth = 5,
  double thumbHeight = 20,
}) {
  return M3ESliderDecoration(
    haptic: M3EHapticFeedback.light,
    hapticConfig: const M3EHapticConfig(
      deltaProgressForDragThreshold: 0.04,
      progressBasedDragMinScale: 0.05,
      progressBasedDragMaxScale: 0.45,
      additionalVelocityMaxBump: 0.05,
      minimumDragInterval: Duration(milliseconds: 45),
    ),
    trackHeight: trackHeight,
    trackCornerRadius: trackHeight / 2,
    thumbWidth: thumbWidth,
    thumbHeight: thumbHeight,
    colors: M3ESliderColors(
      thumbColor: activeColor,
      disabledThumbColor: activeColor,
      activeTrackColor: activeColor,
      inactiveTrackColor: inactiveColor,
      disabledActiveTrackColor: activeColor,
      disabledInactiveTrackColor: inactiveColor,
      activeTickColor: activeColor,
      inactiveTickColor: inactiveColor,
      disabledActiveTickColor: activeColor,
      disabledInactiveTickColor: inactiveColor,
    ),
  );
}

/// A like/heart toggle with a springy pop and an expanding "burst" ring.
/// Feels alive: a quick ring whoosh + pop of the heart when it's turned on.
class AnimatedLikeButton extends StatefulWidget {
  final bool isLiked;
  final double size;
  final Color? likedColor;
  final VoidCallback? onTap;

  const AnimatedLikeButton({
    required this.isLiked,
    super.key,
    this.size = 22,
    this.likedColor,
    this.onTap,
  });

  @override
  State<AnimatedLikeButton> createState() => _AnimatedLikeButtonState();
}

class _AnimatedLikeButtonState extends State<AnimatedLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final Animation<double> _ringGrowth = CurvedAnimation(
    parent: _burst,
    curve: const Interval(0, 0.55, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _ringFade = Tween<double>(
    begin: 0.5,
    end: 0,
  ).animate(CurvedAnimation(parent: _burst, curve: Curves.easeOut));

  @override
  void didUpdateWidget(covariant AnimatedLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isLiked && widget.isLiked) {
      _burst.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hexSize = widget.size;
    final color = widget.isLiked
        ? (widget.likedColor ?? Colors.redAccent)
        : cs.onSurfaceVariant;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: hexSize + 12,
          height: hexSize + 12,
          child: AnimatedBuilder(
            animation: _burst,
            builder: (context, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (_burst.isAnimating || _burst.value > 0)
                    CustomPaint(
                      size: Size(hexSize * 2.4, hexSize * 2.4),
                      painter: _BurstPainter(
                        progress: _ringGrowth.value,
                        opacity: _ringFade.value,
                        color: color,
                      ),
                    ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeInCubic,
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
                      widget.isLiked ? Icons.favorite : Icons.favorite_border,
                      key: ValueKey<bool>(widget.isLiked),
                      size: hexSize,
                      color: color,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  final double progress;
  final double opacity;
  final Color color;

  _BurstPainter({
    required this.progress,
    required this.opacity,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || opacity <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = color.withValues(alpha: opacity);
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      (size.shortestSide / 2) * progress,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _BurstPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.opacity != opacity ||
        oldDelegate.color != color;
  }
}

/// Current global rect of the on-screen player cover (desktop player bar or
/// mobile mini player). Updated by [PlayerCoverRectReporter] — used as the
/// landing spot for the cover fly-to-player animation.
final ValueNotifier<Rect?> playerCoverRectNotifier = ValueNotifier<Rect?>(null);

/// Wraps the player cover and keeps [playerCoverRectNotifier] in sync with its
/// position/size so track covers in lists can "fly" toward it.
class PlayerCoverRectReporter extends StatelessWidget {
  const PlayerCoverRectReporter({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      playerCoverRectNotifier.value = box.localToGlobal(Offset.zero) & box.size;
    }
    return child;
  }
}

/// Animates a copy of a track cover from its current position to the player
/// cover — the "hero" feel without hero widgets (sections switch via signals,
/// not routes). No-op when either source or target is unavailable.
void flyCoverToPlayer(
  BuildContext context, {
  required GlobalKey coverKey,
  required String? coverUrl,
  required double borderRadius,
}) {
  final target = playerCoverRectNotifier.value;
  final fromContext = coverKey.currentContext;
  if (target == null || coverUrl == null || fromContext == null) return;
  final fromBox = fromContext.findRenderObject();
  if (fromBox is! RenderBox || !fromBox.hasSize) return;
  final source = fromBox.localToGlobal(Offset.zero) & fromBox.size;
  if (source.isEmpty || target.isEmpty) return;

  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FlyingCover(
      source: source,
      target: target,
      coverUrl: coverUrl,
      borderRadius: borderRadius,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _FlyingCover extends StatefulWidget {
  final Rect source;
  final Rect target;
  final String coverUrl;
  final double borderRadius;
  final VoidCallback onDone;

  const _FlyingCover({
    required this.source,
    required this.target,
    required this.coverUrl,
    required this.borderRadius,
    required this.onDone,
  });

  @override
  State<_FlyingCover> createState() => _FlyingCoverState();
}

class _FlyingCoverState extends State<_FlyingCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_controller.forward().whenComplete(widget.onDone));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: _t,
          builder: (context, _) {
            final rect = Rect.lerp(
              widget.source,
              widget.target,
              _t.value,
            );
            if (rect == null) return const SizedBox.shrink();
            final radius = ui.lerpDouble(
              widget.borderRadius,
              AppRadius.sm,
              _t.value,
            );
            return Positioned(
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius ?? AppRadius.sm),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: 0.25 * (1 - _t.value),
                      ),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius ?? AppRadius.sm),
                  child: RustCachedImage(
                    imageUrl: widget.coverUrl,
                    width: rect.width,
                    height: rect.height,
                    errorWidget: const ColoredBox(color: Colors.black26),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
