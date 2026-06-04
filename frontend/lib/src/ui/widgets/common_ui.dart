import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/responsive.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';

String formatDuration(int ms) {
  final d = Duration(milliseconds: ms);
  return "${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}";
}

class CommonLoadingWidget extends StatelessWidget {
  const CommonLoadingWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: CircularProgressIndicator(
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
      child: Text('Ошибка: $error', style: const TextStyle(color: Colors.red)),
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
        style: TextStyle(
          fontSize: isNarrow ? 20 : 24,
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    final actualCoverSize = isNarrow
        ? (screenWidth - 80).clamp(150.0, 200.0)
        : coverSize;

    final content = Column(
      crossAxisAlignment: isNarrow
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
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
          textAlign: isNarrow ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            fontSize: isNarrow ? 32 : 48,
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
            fontSize: isNarrow ? 18 : 24,
            color: Colors.white70,
            alignment: isNarrow ? WrapAlignment.center : WrapAlignment.start,
          ),
        ] else if (subtitle != null) ...[
          const SizedBox(height: 12),
          Text(
            subtitle!,
            textAlign: isNarrow ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: isNarrow ? 18 : 24,
              color: Colors.white70,
            ),
          ),
        ],
        if (secondarySubtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            secondarySubtitle!,
            textAlign: isNarrow ? TextAlign.center : TextAlign.start,
            style: const TextStyle(color: Colors.white38),
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
    return Watch((context) {
      final volume = playerVolumeSignal().toDouble();
      final displayVolume = _dragVolume ?? volume;

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
            value: displayVolume.clamp(0, 100),
            max: 100,
            onChanged: (val) {
              setState(() => _dragVolume = val);
              unawaited(PlaybackController.changeVolume(val.toInt()));
            },
            onChangeEnd: (_) {
              setState(() => _dragVolume = null);
            },
          ),
        ),
      );
    });
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
    return Watch((context) {
      final devices = audioDevicesSignal.value;
      final selectedDevice = selectedAudioDeviceSignal.value;
      final accentColor = accentColorSignal.value;

      return IconButton(
        icon: Icon(
          Icons.speaker_group_rounded,
          size: widget.iconSize,
          color: selectedDevice != null ? accentColor : Colors.white38,
        ),
        tooltip: selectedDevice ?? 'Устройство вывода',
        onPressed: () async {
          if (!_devicesLoaded) {
            unawaited(_loadDevices());
          }
          final value = await showMenu<String>(
            context: context,
            color: const Color(0xFF2A2A2A),
            position: _menuPosition(context),
            items: _buildMenuItems(devices, selectedDevice),
          );
          if (value != null) {
            unawaited(setAudioDevice(value));
          }
        },
      );
    });
  }

  RelativeRect _menuPosition(BuildContext context) {
    final renderBox = context.findRenderObject()! as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    return RelativeRect.fromLTRB(
      offset.dx,
      offset.dy + size.height + 4,
      offset.dx + 200,
      offset.dy + size.height + 200,
    );
  }

  List<PopupMenuEntry<String>> _buildMenuItems(
    List<String> devices,
    String? selectedDevice,
  ) {
    return [
      PopupMenuItem<String>(
        value: '',
        child: Text(
          'По умолчанию',
          style: TextStyle(
            color: selectedDevice == null ? Colors.white : Colors.white70,
            fontSize: 13,
          ),
        ),
      ),
      ...devices.map(
        (device) => PopupMenuItem<String>(
          value: device,
          child: Text(
            device,
            style: TextStyle(
              color: device == selectedDevice ? Colors.white : Colors.white70,
              fontSize: 13,
            ),
          ),
        ),
      ),
    ];
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
      child: Watch((context) {
        final progress = trackProgressSignal();
        final dur = progress.durationMs;
        final displayPosition = _dragValue ?? progress.positionMs;
        final trackHeight = widget.compact ? 4.0 : 6.0;
        final thumbRadius = widget.compact ? 4.0 : 6.0;
        final fontSize = widget.compact ? 11.0 : 12.0;
        final accentColor = widget.accentColor ?? accentColorSignal.value;

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
                        activeTrackColor: accentColor,
                        inactiveTrackColor: Colors.white10,
                        thumbColor: accentColor,
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
                          unawaited(
                            PlaybackController.seekTo(
                              Duration(milliseconds: val.toInt()),
                            ),
                          );
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
                  Theme(
                    data: Theme.of(context).copyWith(
                      sliderTheme: SliderThemeData(
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                    ),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: trackHeight,
                        activeTrackColor: accentColor,
                        inactiveTrackColor: Colors.white10,
                        thumbColor: accentColor,
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
                          unawaited(
                            PlaybackController.seekTo(
                              Duration(milliseconds: val.toInt()),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
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
