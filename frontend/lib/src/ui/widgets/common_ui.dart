import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

String formatDuration(int ms) {
  final d = Duration(milliseconds: ms);
  return "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";
}

class CommonLoadingWidget extends StatelessWidget {
  const CommonLoadingWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary));
  }
}

class CommonErrorWidget extends StatelessWidget {
  final String error;
  const CommonErrorWidget({required this.error, super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Ошибка: $error', style: const TextStyle(color: Colors.red)),
    );
  }
}

class CommonSectionTitle extends StatelessWidget {
  final String title;
  final EdgeInsets padding;

  const CommonSectionTitle({
    required this.title,
    super.key,
    this.padding = const EdgeInsets.symmetric(vertical: 24, horizontal: 40),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.white,
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
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Row(
        crossAxisAlignment: isCircle
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.end,
        children: [
          TrackCover(
            url: coverUrl,
            size: coverSize,
            borderRadius: 16,
            isCircle: isCircle,
            canExpand: true,
          ),
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  type.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white54,
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1.1,
                    letterSpacing: -1,
                  ),
                ),
                if (artists != null) ...[
                  const SizedBox(height: 12),
                  ArtistNamesWidget(
                    artists: artists!,
                    fontSize: 24,
                    color: Colors.white70,
                  ),
                ] else if (subtitle != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    subtitle!,
                    style: const TextStyle(fontSize: 24, color: Colors.white70),
                  ),
                ],
                if (secondarySubtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    secondarySubtitle!,
                    style: const TextStyle(color: Colors.white38),
                  ),
                ],
                if (actions != null) ...[
                  const SizedBox(height: 24),
                  Row(children: actions!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CommonVolumeSlider extends StatefulWidget {
  final int initialVolume;
  final double width;
  final Color? activeColor;
  const CommonVolumeSlider({
    required this.initialVolume,
    super.key,
    this.width = 120,
    this.activeColor,
  });

  @override
  State<CommonVolumeSlider> createState() => _CommonVolumeSliderState();
}

class _CommonVolumeSliderState extends State<CommonVolumeSlider> {
  late double _currentVolume;

  @override
  void initState() {
    super.initState();
    _currentVolume = widget.initialVolume.toDouble();
  }

  @override
  void didUpdateWidget(CommonVolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _currentVolume = widget.initialVolume.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.activeColor ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.width,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          activeTrackColor: activeColor,
          thumbColor: activeColor,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
        ),
        child: Slider(
          value: _currentVolume.clamp(0, 100),
          max: 100,
          onChanged: (val) {
            setState(() => _currentVolume = val);
            unawaited(PlaybackController.changeVolume(val.toInt()));
          },
        ),
      ),
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
      error: (Object e, _) => error != null ? error!(e.toString()) : CommonErrorWidget(error: e.toString()),
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
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
    );
  }
}

class CommonProgressSlider extends StatefulWidget {
  final Color accentColor;
  final double maxWidth;
  final bool compact;
  const CommonProgressSlider({
    required this.accentColor,
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
      child: Watch((context) {
        final progress = trackProgressSignal();
        final dur = progress.durationMs;
        final displayPosition = _dragValue ?? progress.positionMs;
        final trackHeight = widget.compact ? 4.0 : 6.0;
        final thumbRadius = widget.compact ? 4.0 : 6.0;
        final fontSize = widget.compact ? 11.0 : 12.0;

        return widget.compact
            ? Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      formatDuration(displayPosition.toInt()),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: trackHeight,
                        activeTrackColor: widget.accentColor,
                        inactiveTrackColor: Colors.white10,
                        thumbColor: widget.accentColor,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: thumbRadius,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                        trackShape: const RoundedRectSliderTrackShape(),
                      ),
                      child: Slider(
                        value: displayPosition.clamp(
                          0,
                          dur > 0 ? dur : 1.0,
                        ),
                        max: dur > 0 ? dur : 1.0,
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
                          unawaited(PlaybackController.seekTo(
                            Duration(milliseconds: val.toInt()),
                          ));
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      formatDuration(dur.toInt()),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: trackHeight,
                      activeTrackColor: widget.accentColor,
                      inactiveTrackColor: Colors.white10,
                      thumbColor: widget.accentColor,
                      thumbShape: RoundSliderThumbShape(
                        enabledThumbRadius: thumbRadius,
                      ),
                      trackShape: const RoundedRectSliderTrackShape(),
                    ),
                    child: Slider(
                      value: displayPosition.clamp(0.0, dur),
                      max: dur,
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
                        unawaited(PlaybackController.seekTo(
                          Duration(milliseconds: val.toInt()),
                        ));
                      },
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(displayPosition.toInt()),
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: fontSize,
                        ),
                      ),
                      Text(
                        formatDuration(dur.toInt()),
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: fontSize,
                        ),
                      ),
                    ],
                  ),
                ],
              );
      }),
    );
  }
}
