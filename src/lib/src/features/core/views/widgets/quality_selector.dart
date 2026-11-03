import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/audio_settings.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class CommonQualitySelector extends SignalWidget {
  final Color? accentColor;
  final double iconSize;

  const CommonQualitySelector({
    this.accentColor,
    super.key,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final quality = audioQualitySignal.value;
        final meta = trackMetadataSignal.value;
        // No accent subscription while the hosting tab is hidden.
        final accentColor =
            this.accentColor ??
            visibleSignal<Color>(context, accentColorSignal);

        final items = <AppContextMenuItem<dynamic>>[];

        if (meta.codec != null) {
          items.add(
            AppContextMenuItem(
              label: 'ПОТОК: ${meta.codec!.toUpperCase()}',
              icon: Icons.info_outline_rounded,
              color: accentColor,
            ),
          );
        }

        items.addAll([
          AppContextMenuItem(
            value: AudioQuality.low,
            label: 'Низкое качество',
            leading: _QualityIcon(
              label: 'LQ',
              color: quality == AudioQuality.low ? accentColor : null,
            ),
            isSelected: quality == AudioQuality.low,
            color: quality == AudioQuality.low ? accentColor : null,
          ),
          AppContextMenuItem(
            value: AudioQuality.normal,
            label: 'Стандартное качество',
            leading: _QualityIcon(
              label: 'NQ',
              color: quality == AudioQuality.normal ? accentColor : null,
            ),
            isSelected: quality == AudioQuality.normal,
            color: quality == AudioQuality.normal ? accentColor : null,
          ),
          AppContextMenuItem(
            value: AudioQuality.high,
            label: 'Высокое качество',
            leading: _QualityIcon(
              label: 'HQ',
              color: quality == AudioQuality.high ? accentColor : null,
            ),
            isSelected: quality == AudioQuality.high,
            color: quality == AudioQuality.high ? accentColor : null,
          ),
          AppContextMenuItem(
            label: 'Устройство вывода',
            icon: Icons.speaker_group_rounded,
            subItems: () {
              final devices = audioDevicesSignal.value;
              final selectedDevice = selectedAudioDeviceSignal.value;
              return <AppContextMenuItem<dynamic>>[
                AppContextMenuItem<dynamic>(
                  value: const _DeviceChoice(''),
                  label: 'По умолчанию',
                  icon: Icons.computer_rounded,
                  isSelected: selectedDevice == null,
                  color: selectedDevice == null ? accentColor : null,
                ),
                ...devices.map(
                  (device) => AppContextMenuItem<dynamic>(
                    value: _DeviceChoice(device),
                    label: device,
                    icon: Icons.speaker_rounded,
                    isSelected: device == selectedDevice,
                    color: device == selectedDevice ? accentColor : null,
                  ),
                ),
              ];
            },
          ),
          const AppContextMenuItem(
            value: 'eq',
            label: 'Настройки звука',
            icon: Icons.tune_rounded,
          ),
        ]);

        return AppContextMenu<dynamic>(
          // Device list changes with plug/unplug — refresh on every open.
          onOpen: () => unawaited(refreshAudioDevices()),
          hoverColor: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
          // Same rounding as the global iconButtonTheme (14) so the hover
          // backdrop matches the surrounding player buttons.
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          onSelected: (val) {
            if (val is AudioQuality) {
              unawaited(PlaybackController.setQuality(val));
            } else if (val is _DeviceChoice) {
              unawaited(setAudioDevice(val.name));
            } else if (val == 'eq') {
              unawaited(refreshEqualizer());
              unawaited(refreshAudioEffects());
              if (Platform.isAndroid) {
                unawaited(
                  showAppBottomSheet<void>(
                    context: context,
                    builder: (_) =>
                        const AudioSettingsDialog(bottomSheet: true),
                  ),
                );
              } else {
                showDialog<void>(
                  context: context,
                  builder: (context) => const AudioSettingsDialog(),
                );
              }
            }
          },
          items: items,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: Icon(
                Icons.speed_rounded,
                size: iconSize,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Output device choice inside the quality menu; wrapped so arbitrary
/// device names can never collide with the other menu values.
class _DeviceChoice {
  const _DeviceChoice(this.name);
  final String name;
}

class _QualityIcon extends StatelessWidget {
  final String label;
  final Color? color;
  const _QualityIcon({required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
