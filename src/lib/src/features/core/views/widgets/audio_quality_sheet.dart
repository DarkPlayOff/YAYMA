import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/audio_settings.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Bottom sheet with the stream quality choice. Below the list there is an
/// entry that opens the equalizer / DSP effects sheet.
Future<void> showAudioQualitySheet(BuildContext context) {
  return showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const _AudioQualitySheet(),
  );
}

class _AudioQualitySheet extends StatelessWidget {
  const _AudioQualitySheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: SignalBuilder(
          builder: (context) {
            final cs = Theme.of(context).colorScheme;
            final quality = audioQualitySignal.value;
            final meta = trackMetadataSignal.value;
            final accent = accentColorSignal.value;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 2),
                  child: Text(
                    'Качество звука',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    meta.codec == null
                        ? 'Выберите битрейт потока'
                        : 'Текущий поток: ${meta.codec!.toUpperCase()}',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                _QualityOption(
                  label: 'Низкое качество',
                  code: 'LQ',
                  value: AudioQuality.low,
                  current: quality,
                  accent: accent,
                ),
                _QualityOption(
                  label: 'Стандартное качество',
                  code: 'NQ',
                  value: AudioQuality.normal,
                  current: quality,
                  accent: accent,
                ),
                _QualityOption(
                  label: 'Высокое качество',
                  code: 'HQ',
                  value: AudioQuality.high,
                  current: quality,
                  accent: accent,
                ),
                Divider(
                  height: 16,
                  indent: 24,
                  endIndent: 24,
                  color: cs.onSurface.withValues(alpha: 0.08),
                ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  leading: Icon(Icons.graphic_eq_rounded, color: accent),
                  title: Text(
                    'Эквалайзер',
                    style: TextStyle(color: cs.onSurface, fontSize: 16),
                  ),
                  subtitle: Text(
                    'Частоты, пресеты и эффекты',
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () => unawaited(_openEqualizer(context)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openEqualizer(BuildContext context) async {
    unawaited(refreshEqualizer());
    unawaited(refreshAudioEffects());

    final navigator = Navigator.of(context)..pop();
    await showAppBottomSheet<void>(
      context: navigator.context,
      builder: (_) => const AudioSettingsDialog(bottomSheet: true),
    );
  }
}

class _QualityOption extends StatelessWidget {
  final String label;
  final String code;
  final AudioQuality value;
  final AudioQuality current;
  final Color accent;

  const _QualityOption({
    required this.label,
    required this.code,
    required this.value,
    required this.current,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = value == current;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onTap: selected
          ? null
          : () => unawaited(PlaybackController.setQuality(value)),
      leading: SizedBox(
        width: 36,
        child: Center(
          child: Text(
            code,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: selected ? accent : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? accent : cs.onSurface,
          fontSize: 16,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check_rounded, size: 22, color: accent)
          : null,
    );
  }
}
