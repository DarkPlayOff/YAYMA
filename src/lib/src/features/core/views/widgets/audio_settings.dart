import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class AudioSettingsDialog extends StatefulWidget {
  final bool bottomSheet;

  const AudioSettingsDialog({super.key, this.bottomSheet = false});

  @override
  State<AudioSettingsDialog> createState() => _AudioSettingsDialogState();
}

class _AudioSettingsDialogState extends State<AudioSettingsDialog> {
  int _activeTab = 0; // 0: EQ, 1: FX

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final tabs = [
          const Tab(text: 'Эквалайзер'),
          const Tab(text: 'Эффекты (DSP)'),
        ];

        if (widget.bottomSheet) {
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            snap: true,
            expand: false,
            builder: (context, scrollController) {
              return DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TabBar(
                        onTap: (i) => setState(() => _activeTab = i),
                        indicatorColor: accentColorSignal.value,
                        labelColor: Colors.white,
                        unselectedLabelColor: Colors.white38,
                        tabs: tabs,
                      ),
                    ),
                    const Divider(height: 1, color: Colors.white10),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: TabBarView(
                          physics: NeverScrollableScrollPhysics(),
                          children: [
                            _EqualizerView(),
                            _EffectsView(),
                          ],
                        ),
                      ),
                    ),
                    if (_activeTab == 0)
                      TextButton(
                        onPressed: () =>
                            unawaited(PlaybackController.resetEqualizer()),
                        child: const Text(
                          'Сбросить',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        }

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
                  tabs: tabs,
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
                  onPressed: () =>
                      unawaited(PlaybackController.resetEqualizer()),
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
      },
    );
  }
}

class _EqualizerView extends StatelessWidget {
  const _EqualizerView();

  // Height reserved above each slider for the gain value, and below for the
  // frequency label. Kept in sync across the ruler, grid and bands so they
  // stay aligned regardless of screen size.
  static const double _gainBlockHeight = 24;
  static const double _freqBlockHeight = 22;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final eq = equalizerSignal.value;
        if (eq == null) {
          return const Center(child: CircularProgressIndicator());
        }

        final accent = accentColorSignal.value;
        final enabled = eq.enabled;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(accent, enabled),
            Expanded(
              child: AnimatedOpacity(
                opacity: enabled ? 1 : 0.45,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 18, 12, 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildGainRuler(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            const minBandWidth = 38.0;
                            final bandCount = eq.bands.length;
                            final needsScroll =
                                constraints.maxWidth < minBandWidth * bandCount;

                            final bandsRow = Row(
                              children: eq.bands.map((band) {
                                final child = _buildBand(
                                  context,
                                  band,
                                  accent,
                                  enabled,
                                );
                                return needsScroll
                                    ? SizedBox(width: minBandWidth, child: child)
                                    : Expanded(child: child);
                              }).toList(),
                            );

                            final content = Stack(
                              children: [
                                Positioned.fill(child: _buildGrid(accent)),
                                bandsRow,
                              ],
                            );

                            if (!needsScroll) return content;

                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: minBandWidth * bandCount,
                                height: constraints.maxHeight,
                                child: content,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(Color accent, bool enabled) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.graphic_eq_rounded,
            size: 22,
            color: enabled ? accent : Colors.white30,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Эквалайзер',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? 'Активен' : 'Выключен',
                  style: TextStyle(
                    color: enabled ? accent : Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (val) => unawaited(
              PlaybackController.setEqualizerEnabled(enabled: val),
            ),
            activeThumbColor: accent,
          ),
        ],
      ),
    );
  }

  Widget _buildGainRuler() {
    const labels = ['+12', '+6', '0', '-6', '-12'];
    return SizedBox(
      width: 30,
      child: Column(
        children: [
          const SizedBox(height: _gainBlockHeight),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: labels
                  .map(
                    (t) => Text(
                      t,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white30,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: _freqBlockHeight),
        ],
      ),
    );
  }

  Widget _buildGrid(Color accent) {
    return Column(
      children: [
        const SizedBox(height: _gainBlockHeight),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(5, (i) {
              final isZero = i == 2;
              return Container(
                height: 1,
                color: isZero
                    ? accent.withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.05),
              );
            }),
          ),
        ),
        const SizedBox(height: _freqBlockHeight),
      ],
    );
  }

  Widget _buildBand(
    BuildContext context,
    BandDto band,
    Color accent,
    bool enabled,
  ) {
    final gain = band.gainDb.clamp(-12.0, 12.0);
    final isNeutral = gain.abs() < 0.05;

    return Column(
      children: [
        SizedBox(
          height: _gainBlockHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isNeutral
                    ? Colors.white.withValues(alpha: 0.05)
                    : accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(1)}',
                style: TextStyle(
                  fontSize: 9,
                  color: isNeutral ? Colors.white38 : accent,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: accent.withValues(alpha: enabled ? 0.7 : 0.3),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                thumbColor: enabled ? accent : Colors.white38,
                overlayColor: accent.withValues(alpha: 0.15),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: gain,
                min: -12,
                max: 12,
                onChanged: enabled
                    ? (val) => unawaited(
                        PlaybackController.setEqualizerBand(band.index, val),
                      )
                    : null,
              ),
            ),
          ),
        ),
        SizedBox(
          height: _freqBlockHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _formatFreq(band.frequency),
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatFreq(double freq) {
    if (freq >= 1000) {
      return '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}к';
    }
    return '${freq.toInt()}';
  }
}

class _EffectsView extends StatelessWidget {
  const _EffectsView();

  // Matches the effect ids registered in src/rust/src/audio/fx/init.rs.
  static const _icons = <String, IconData>{
    'chorus': Icons.waves_rounded, // layered, wavering pitch
    'lowpass': Icons.arrow_downward_rounded, // lets lows through
    'highpass': Icons.arrow_upward_rounded, // lets highs through
    'bandpass': Icons.swap_horiz_rounded, // passes a band, cuts both sides
    'notch': Icons.remove_rounded, // cuts a thin band out
    'dc_block': Icons.horizontal_rule_rounded, // flattens the DC offset
    'reverb': Icons.blur_on_rounded, // diffuse, spatial reflections
    'delay': Icons.repeat_rounded, // repeating echoes
    'compressor': Icons.compress_rounded, // squeezes dynamic range
    'overdrive': Icons.bolt_rounded, // driven/distorted signal
  };

  IconData _iconFor(String id) => _icons[id] ?? Icons.tune_rounded;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final effects = audioEffectsSignal.value;
        if (effects.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final accent = accentColorSignal.value;

        return ListView.separated(
          itemCount: effects.length,
          padding: const EdgeInsets.symmetric(vertical: 16),
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final effect = effects[index];
            return _EffectCard(
              effect: effect,
              accent: accent,
              icon: _iconFor(effect.id),
            );
          },
        );
      },
    );
  }
}

class _EffectCard extends StatefulWidget {
  final AudioEffectDto effect;
  final Color accent;
  final IconData icon;

  const _EffectCard({
    required this.effect,
    required this.accent,
    required this.icon,
  });

  @override
  State<_EffectCard> createState() => _EffectCardState();
}

class _EffectCardState extends State<_EffectCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final effect = widget.effect;
    final accent = widget.accent;
    final enabled = effect.enabled;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: _expanded ? 0.05 : 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: enabled
              ? accent.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: enabled
                          ? accent.withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      widget.icon,
                      size: 18,
                      color: enabled ? accent : Colors.white30,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          effect.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          enabled ? 'Включён' : 'Выключен',
                          style: TextStyle(
                            color: enabled ? accent : Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: (val) => unawaited(
                      PlaybackController.setEffectEnabled(
                        effect.id,
                        enabled: val,
                      ),
                    ),
                    activeThumbColor: accent,
                  ),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    turns: _expanded ? 0.5 : 0,
                    child: const Icon(
                      Icons.expand_more_rounded,
                      color: Colors.white38,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                children: [
                  const Divider(height: 1, color: Colors.white10),
                  const SizedBox(height: 10),
                  ...effect.params.map(
                    (param) => _EffectParamRow(
                      param: param,
                      accent: accent,
                      enabled: enabled,
                      onChanged: (val) => unawaited(
                        PlaybackController.setEffectParam(
                          effect.id,
                          param.index,
                          val,
                        ),
                      ),
                    ),
                  ),
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
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _EffectParamRow extends StatelessWidget {
  final EffectParamDto param;
  final Color accent;
  final bool enabled;
  final ValueChanged<double> onChanged;

  const _EffectParamRow({
    required this.param,
    required this.accent,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDefault = (param.value - param.defaultValue).abs() < 0.001;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              param.name,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: accent.withValues(alpha: enabled ? 0.7 : 0.3),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                thumbColor: enabled ? accent : Colors.white38,
                overlayColor: accent.withValues(alpha: 0.15),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: param.value.clamp(param.min, param.max),
                min: param.min,
                max: param.max,
                divisions: param.step > 0
                    ? ((param.max - param.min) / param.step).toInt()
                    : null,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isDefault
                    ? Colors.white.withValues(alpha: 0.05)
                    : accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${param.value.toStringAsFixed(1)}${param.unit}',
                style: TextStyle(
                  fontSize: 10,
                  color: isDefault ? Colors.white38 : accent,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EqualizerDialog extends StatelessWidget {
  const EqualizerDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return const AudioSettingsDialog();
  }
}
