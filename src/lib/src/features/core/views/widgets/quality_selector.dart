import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/audio_settings.dart';
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
        final accentColor = this.accentColor ?? accentColorSignal.value;

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
          const AppContextMenuItem(
            value: 'eq',
            label: 'Настройки звука',
            icon: Icons.tune_rounded,
          ),
        ]);

        return AppContextMenu<dynamic>(
          onSelected: (val) {
            if (val is AudioQuality) {
              unawaited(PlaybackController.setQuality(val));
            } else if (val == 'eq') {
              unawaited(refreshEqualizer());
              unawaited(refreshAudioEffects());
              if (Platform.isAndroid) {
                unawaited(
                  showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(AppRadius.xl),
                      ),
                    ),
                    builder: (_) =>
                        const AudioSettingsDialog(bottomSheet: true),
                  ),
                );
              } else {
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (context) => const AudioSettingsDialog(),
                  ),
                );
              }
            }
          },
          items: items,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: Icon(
            Icons.speed_rounded,
            size: iconSize,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
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
