import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/audio_settings.dart';

class CommonQualitySelector extends StatelessWidget {
  final Color accentColor;
  final bool isSmall;

  const CommonQualitySelector({
    required this.accentColor,
    super.key,
    this.isSmall = false,
  });

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final quality = audioQualitySignal.value;
      final meta = trackMetadataSignal.watch(context);

      var label = '';
      switch (quality) {
        case AudioQuality.low:
          label = 'LQ';
        case AudioQuality.normal:
          label = 'NQ';
        case AudioQuality.high:
          label = 'HQ';
      }

      return PopupMenuButton<dynamic>(
        tooltip: 'Качество и звук',
        onSelected: (val) {
          if (val is AudioQuality) {
            unawaited(PlaybackController.setQuality(val));
          } else if (val == 'eq') {
            unawaited(refreshEqualizer());
            unawaited(refreshAudioEffects());
            unawaited(showDialog<void>(
              context: context,
              builder: (context) => const AudioSettingsDialog(),
            ));
          }
        },
        color: const Color(0xFF2A2A2E),
        offset: const Offset(0, -200),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.white10),
        ),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: isSmall ? 8 : 10,
            vertical: isSmall ? 4 : 5,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
            color: Colors.white.withValues(alpha: 0.05),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: quality == AudioQuality.high ? accentColor : Colors.white,
              fontSize: isSmall ? 11 : 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        itemBuilder: (context) => [
          if (meta.codec != null) ...[
            PopupMenuItem(
              enabled: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ТЕКУЩИЙ ПОТОК',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        meta.codec!.toUpperCase(),
                        style: TextStyle(
                          color: accentColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(),
          ],
          const PopupMenuItem(
            enabled: false,
            child: Text(
              'Качество треков',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _buildItem(context, AudioQuality.low, 'LQ', 'Низкое', quality),
          _buildItem(context, AudioQuality.normal, 'NQ', 'Стандартное', quality),
          _buildItem(context, AudioQuality.high, 'HQ', 'Высокое', quality),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'eq',
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, color: Colors.white70, size: 20),
                const SizedBox(width: 12),
                const Text(
                  'Настройки звука',
                  style: TextStyle(color: Colors.white),
                ),
                const Spacer(),
                if ((equalizerSignal.value?.enabled ?? false) ||
                    audioEffectsSignal.value.any((e) => e.enabled))
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }

  PopupMenuItem<AudioQuality> _buildItem(
    BuildContext context,
    AudioQuality value,
    String label,
    String desc,
    AudioQuality current,
  ) {
    final isSelected = value == current;
    final primaryColor = Theme.of(context).colorScheme.primary;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: isSelected ? primaryColor : Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            desc,
            style: TextStyle(
              color: isSelected
                  ? primaryColor.withValues(alpha: 0.7)
                  : Colors.white54,
              fontSize: 13,
            ),
          ),
          if (isSelected) ...[
            const Spacer(),
            Icon(Icons.check_rounded, color: primaryColor, size: 18),
          ],
        ],
      ),
    );
  }
}
