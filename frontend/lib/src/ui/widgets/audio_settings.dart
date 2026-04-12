import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/playback_provider.dart';

class AudioSettingsDialog extends StatefulWidget {
  const AudioSettingsDialog({super.key});

  @override
  State<AudioSettingsDialog> createState() => _AudioSettingsDialogState();
}

class _AudioSettingsDialogState extends State<AudioSettingsDialog> {
  int _activeTab = 0; // 0: EQ, 1: FX

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        backgroundColor: const Color(0xFF181818),
        titlePadding: EdgeInsets.zero,
        title: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Row(
                children: [
                  const Text(
                    'Настройки звука',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            TabBar(
              onTap: (i) => setState(() => _activeTab = i),
              indicatorColor: accentColorSignal.value,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white38,
              tabs: const [
                Tab(text: 'Эквалайзер'),
                Tab(text: 'Эффекты (DSP)'),
              ],
            ),
          ],
        ),
        content: const SizedBox(
          width: 700,
          height: 450,
          child: TabBarView(
            physics: NeverScrollableScrollPhysics(),
            children: [
              _EqualizerView(),
              _EffectsView(),
            ],
          ),
        ),
        actions: [
          if (_activeTab == 0)
            TextButton(
              onPressed: () => unawaited(PlaybackController.resetEqualizer()),
              child: const Text(
                'Сбросить',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}

class _EqualizerView extends StatelessWidget {
  const _EqualizerView();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final eq = equalizerSignal.value;
      if (eq == null) {
        return const Center(child: CircularProgressIndicator());
      }

      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                const Text(
                  'Включить эквалайзер',
                  style: TextStyle(color: Colors.white70),
                ),
                const Spacer(),
                Switch(
                  value: eq.enabled,
                  onChanged: (val) =>
                      unawaited(PlaybackController.setEqualizerEnabled(enabled: val)),
                  activeThumbColor: accentColorSignal.value,
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: eq.bands.map((band) {
                return Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                            ),
                            child: Slider(
                              value: band.gainDb.clamp(-12.0, 12.0),
                              min: -12,
                              max: 12,
                              onChanged: eq.enabled
                                  ? (val) =>
                                        unawaited(PlaybackController.setEqualizerBand(
                                          band.index,
                                          val,
                                        ))
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _formatFreq(band.frequency),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${band.gainDb.toStringAsFixed(1)} дБ',
                        style: const TextStyle(
                          fontSize: 9,
                          color: Colors.white24,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      );
    });
  }

  String _formatFreq(double freq) {
    if (freq >= 1000) {
      return '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}кГц';
    }
    return '${freq.toInt()}Гц';
  }
}

class _EffectsView extends StatelessWidget {
  const _EffectsView();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final effects = audioEffectsSignal.value;
      if (effects.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }

      return ListView.separated(
        itemCount: effects.length,
        padding: const EdgeInsets.symmetric(vertical: 16),
        separatorBuilder: (context, index) =>
            const Divider(color: Colors.white10),
        itemBuilder: (context, index) {
          final effect = effects[index];
          return ExpansionTile(
            title: Row(
              children: [
                Text(effect.name, style: const TextStyle(color: Colors.white)),
                const Spacer(),
                Switch(
                  value: effect.enabled,
                  onChanged: (val) =>
                      unawaited(PlaybackController.setEffectEnabled(effect.id, enabled: val)),
                  activeThumbColor: accentColorSignal.value,
                ),
              ],
            ),
            shape: const RoundedRectangleBorder(),
            collapsedIconColor: Colors.white38,
            iconColor: accentColorSignal.value,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  children: [
                    ...effect.params.map((param) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 100,
                              child: Text(
                                param.name,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5,
                                  ),
                                ),
                                child: Slider(
                                  value: param.value.clamp(
                                    param.min,
                                    param.max,
                                  ),
                                  min: param.min,
                                  max: param.max,
                                  divisions: param.step > 0
                                      ? ((param.max - param.min) / param.step)
                                            .toInt()
                                      : null,
                                  onChanged: effect.enabled
                                      ? (val) =>
                                            unawaited(PlaybackController.setEffectParam(
                                              effect.id,
                                              param.index,
                                              val,
                                            ))
                                      : null,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 60,
                              child: Text(
                                '${param.value.toStringAsFixed(1)}${param.unit}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () =>
                            unawaited(PlaybackController.resetEffect(effect.id)),
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label: const Text(
                          'Сбросить параметры',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent.withValues(
                            alpha: 0.7,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    });
  }
}

class EqualizerDialog extends StatelessWidget {
  const EqualizerDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return const AudioSettingsDialog();
  }
}
