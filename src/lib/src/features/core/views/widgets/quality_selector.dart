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
  final bool isSmall;

  const CommonQualitySelector({
    this.accentColor,
    super.key,
    this.isSmall = false,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final quality = audioQualitySignal.value;
        final meta = trackMetadataSignal.value;
        final accentColor = this.accentColor ?? accentColorSignal.value;

        var label = '';
        switch (quality) {
          case AudioQuality.low:
            label = 'LQ';
          case AudioQuality.normal:
            label = 'NQ';
          case AudioQuality.high:
            label = 'HQ';
        }

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
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isSmall ? 8 : 10,
              vertical: isSmall ? 4 : 5,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.1),
              ),
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.05),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: quality == AudioQuality.high
                    ? accentColor
                    : Theme.of(context).colorScheme.onSurface,
                fontSize: isSmall ? 11 : 12,
                fontWeight: FontWeight.bold,
              ),
            ),
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
