import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/home_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/providers/wave_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

import 'package:yayma/src/ui/widgets/responsive.dart';

class WaveSettingsPanel extends StatelessWidget {
  final VoidCallback onSelected;
  final ScrollController? scrollController;
  const WaveSettingsPanel({
    required this.onSelected,
    this.scrollController,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final currentSeeds = currentWaveSeedsSignal();
      final isNarrow = context.isNarrow;

      return Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Настроить Мою волну',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () async {
                              await showModalBottomSheet<void>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                isScrollControlled: true,
                                builder: (context) => const _AllStationsSheet(),
                              );
                            },
                            behavior: HitTestBehavior.opaque,
                            child: const Icon(
                              Icons.explore,
                              color: Colors.white54,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        height: 40,
                        child:
                            (currentSeeds.isNotEmpty &&
                                !currentSeeds.contains('user:onyourwave'))
                            ? MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () {
                                    unawaited(WaveController.resetStations());
                                  },
                                  behavior: HitTestBehavior.opaque,
                                  child: const Icon(
                                    Icons.refresh,
                                    color: Colors.white54,
                                    size: 20,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Под занятие'),

                  _buildChips(context, [
                    _VibeItem('Просыпаюсь', 'activity:wake-up'),
                    _VibeItem('В дороге', 'activity:road-trip'),
                    _VibeItem('Работаю', 'activity:work-background'),
                    _VibeItem('Тренируюсь', 'activity:workout'),
                    _VibeItem('Засыпаю', 'activity:fall-asleep'),
                  ], currentSeeds),
                  const SizedBox(height: 24),
                  _buildSectionTitle('По характеру'),
                  Row(
                    children: [
                      _CharacterCard(
                        label: 'Любимое',
                        icon: Icons.favorite,
                        color: Colors.red,
                        seed: 'personal:collection',
                        onSelected: onSelected,
                        isSelected: currentSeeds.contains(
                          'personal:collection',
                        ),
                      ),
                      const SizedBox(width: 12),
                      _CharacterCard(
                        label: 'Незнакомое',
                        icon: Icons.auto_awesome,
                        color: Colors.amber,
                        seed: 'personal:never-heard',
                        onSelected: onSelected,
                        isSelected: currentSeeds.contains(
                          'personal:never-heard',
                        ),
                      ),
                      const SizedBox(width: 12),
                      _CharacterCard(
                        label: 'Популярное',
                        icon: Icons.bolt,
                        color: Colors.white,
                        seed: 'personal:hits',
                        onSelected: onSelected,
                        isSelected: currentSeeds.contains('personal:hits'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildSectionTitle('Под настроение'),
                  _buildMoods([
                    _MoodItem('Бодрое', [
                      Colors.orange,
                      Colors.deepOrange,
                    ], 'mood:energetic'),
                    _MoodItem('Весёлое', [
                      Colors.lightGreen,
                      Colors.lime,
                    ], 'mood:happy'),
                    _MoodItem('Спокойное', [
                      Colors.cyan,
                      Colors.teal,
                    ], 'mood:calm'),
                    _MoodItem('Грустное', [
                      Colors.blue,
                      Colors.indigo,
                    ], 'mood:sad'),
                  ], currentSeeds),
                  const SizedBox(height: 24),
                  _buildSectionTitle('По языку'),
                  _buildChips(context, [
                    _VibeItem('Русский', 'local-language:russian'),
                    _VibeItem('Иностранный', 'local-language:english'),
                    _VibeItem('Без слов', 'local-language:instrumental'),
                  ], currentSeeds),
                  const SizedBox(height: 24),
                  if (currentSeeds.isNotEmpty &&
                      !currentSeeds.contains('user:onyourwave') &&
                      !_isMainSeed(currentSeeds.first))
                    _buildActiveExtraStation(currentSeeds.first),
                ],
              ),
            ),
            if (isNarrow)
              Positioned(
                right: 24,
                bottom: 32,
                child: FloatingActionButton(
                  onPressed: () {
                    unawaited(HomeController.startMyWave());
                    onSelected();
                  },
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.black,
                  elevation: 8,
                  child: const Icon(Icons.play_arrow_rounded, size: 28),
                ),
              ),
          ],
        ),
      );
    });
  }

  bool _isMainSeed(String seed) {
    const mainSeeds = {
      'activity:wake-up',
      'activity:road-trip',
      'activity:work-background',
      'activity:workout',
      'activity:fall-asleep',
      'personal:collection',
      'personal:never-heard',
      'personal:hits',
      'mood:energetic',
      'mood:happy',
      'mood:calm',
      'mood:sad',
      'local-language:russian',
      'local-language:english',
      'local-language:instrumental',
    };
    return mainSeeds.contains(seed);
  }

  Widget _buildActiveExtraStation(String seed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle('Активный режим'),
        SignalBuilder(builder: (context) {
          final catsFuture = waveStationsSignal.value;
          var label = seed;

          if (seed.startsWith('track:')) {
            final parts = seed.split(':');
            if (parts.length >= 3) {
              label = parts.sublist(2).join(':');
            }
          }

          if (catsFuture.hasValue) {
            for (final cat in catsFuture.value!) {
              for (final item in cat.items) {
                if (item.seed == seed) {
                  label = item.label;
                  break;
                }
              }
            }
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _RoundedChip(
              item: _VibeItem(label, seed),
              onSelected: onSelected,
              isSelected: true,
            ),
          );
        }),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildChips(
    BuildContext context,
    List<_VibeItem> items,
    List<String> currentSeeds,
  ) {
    if (!context.isNarrow) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items
            .map(
              (i) => _RoundedChip(
                item: i,
                onSelected: onSelected,
                isSelected: currentSeeds.contains(i.seed),
              ),
            )
            .toList(),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: items.asMap().entries.map((entry) {
          final i = entry.value;
          final isLast = entry.key == items.length - 1;
          return Padding(
            padding: EdgeInsets.only(right: isLast ? 0 : 8),
            child: _RoundedChip(
              item: i,
              onSelected: onSelected,
              isSelected: currentSeeds.contains(i.seed),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMoods(List<_MoodItem> moods, List<String> currentSeeds) {
    return Row(
      children: moods
          .map(
            (m) => Expanded(
              child: _MoodCircle(
                mood: m,
                onSelected: onSelected,
                isSelected: currentSeeds.contains(m.seed),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _VibeItem {
  final String label;
  final String seed;
  _VibeItem(this.label, this.seed);
}

class _MoodItem {
  final String label;
  final List<Color> colors;
  final String seed;
  _MoodItem(this.label, this.colors, this.seed);
}

class _RoundedChip extends StatelessWidget {
  final _VibeItem item;
  final VoidCallback onSelected;
  final bool isSelected;
  const _RoundedChip({
    required this.item,
    required this.onSelected,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = context.isNarrow;
    final panelWidth = isNarrow ? (screenWidth - 48) : 480.0;
    final maxLabelWidth = panelWidth - 48 - 40; // Subtract padding for safety

    return FilterChip(
      selected: isSelected,
      label: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth > 0 ? maxLabelWidth : 100),
        child: Text(
          item.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onSelected: (_) {
        unawaited(WaveController.toggleStation(item.seed));
      },
      backgroundColor: Colors.white.withValues(alpha: 0.05),
      selectedColor: Colors.white.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : Colors.white70,
        fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: isSelected
          ? const BorderSide(color: Colors.white24)
          : BorderSide.none,
      showCheckmark: false,
    );
  }
}

class _CharacterCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final String seed;
  final VoidCallback onSelected;
  final bool isSelected;
  const _CharacterCard({
    required this.label,
    required this.icon,
    required this.color,
    required this.seed,
    required this.onSelected,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: () {
          unawaited(WaveController.toggleStation(seed));
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 90,
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? Colors.white30 : Colors.white10,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoodCircle extends StatelessWidget {
  final _MoodItem mood;
  final VoidCallback onSelected;
  final bool isSelected;
  const _MoodCircle({
    required this.mood,
    required this.onSelected,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        unawaited(WaveController.toggleStation(mood.seed));
      },
      borderRadius: BorderRadius.circular(40),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: isSelected ? 56 : 50,
            height: isSelected ? 56 : 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: mood.colors,
              ),
              boxShadow: [
                BoxShadow(
                  color: mood.colors[0].withValues(
                    alpha: isSelected ? 0.6 : 0.4,
                  ),
                  blurRadius: isSelected ? 15 : 10,
                  spreadRadius: isSelected ? 3 : 1,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            mood.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _AllStationsSheet extends StatefulWidget {
  const _AllStationsSheet();

  @override
  State<_AllStationsSheet> createState() => _AllStationsSheetState();
}

class _AllStationsSheetState extends State<_AllStationsSheet> {
  final FlutterSignal<String> _searchQuery = signal('');
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final stationsFuture = waveStationsSignal.value;
      if (stationsFuture.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }

      final currentSeeds = currentWaveSeedsSignal();
      var cats = stationsFuture.value ?? [];
      final query = _searchQuery().toLowerCase();

      if (query.isNotEmpty) {
        cats = cats
            .map(
              (cat) => StationCategoryDto(
                title: cat.title,
                items: cat.items
                    .where((i) => i.label.toLowerCase().contains(query))
                    .toList(),
              ),
            )
            .where((cat) => cat.items.isNotEmpty)
            .toList();
      }

      return Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: const BoxDecoration(
          color: Color(0xFF181818),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Row(
                  children: [
                    const Text(
                      'Каталог станций',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
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
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _controller,
                  onChanged: (v) => _searchQuery.value = v,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Поиск по жанрам, настроениям...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    prefixIcon: const Icon(Icons.search, color: Colors.white24),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              Expanded(
                child: cats.isEmpty && query.isNotEmpty
                    ? const Center(
                        child: Text(
                          'Ничего не найдено',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : Scrollbar(
                        controller: _scrollController,
                        child: CustomScrollView(
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            1000,
                          ),
                          controller: _scrollController,
                          slivers: [
                            for (final cat in cats) ...[
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  24,
                                  24,
                                  12,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: Text(
                                    cat.title.toUpperCase(),
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: cat.items.map((item) {
                                      final isSelected = currentSeeds.contains(
                                        item.seed,
                                      );
                                      final maxSheetLabelWidth = MediaQuery.sizeOf(context).width - 48 - 40; // Subtract modal padding and chip padding
                                      return FilterChip(
                                        selected: isSelected,
                                        label: ConstrainedBox(
                                          constraints: BoxConstraints(maxWidth: maxSheetLabelWidth > 0 ? maxSheetLabelWidth : 100),
                                          child: Text(
                                            item.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        onSelected: (_) {
                                          unawaited(
                                            WaveController.toggleStation(
                                              item.seed,
                                            ),
                                          );
                                          Navigator.pop(context);
                                        },
                                        backgroundColor: Colors.white
                                            .withValues(alpha: 0.05),
                                        selectedColor: Colors.white.withValues(
                                          alpha: 0.2,
                                        ),
                                        labelStyle: TextStyle(
                                          color: isSelected
                                              ? Colors.white
                                              : Colors.white70,
                                          fontWeight: isSelected
                                              ? FontWeight.w900
                                              : FontWeight.w600,
                                          fontSize: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        side: isSelected
                                            ? const BorderSide(
                                                color: Colors.white24,
                                              )
                                            : BorderSide.none,
                                        showCheckmark: false,
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                            ],
                            const SliverPadding(
                              padding: EdgeInsets.only(bottom: 40),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
