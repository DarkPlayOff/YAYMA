import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/providers/wave_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class WaveSettingsPanel extends StatelessWidget {
  final VoidCallback onSelected;
  const WaveSettingsPanel({required this.onSelected, super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final currentSeeds = trackMetadataSignal().currentWaveSeeds;

      return Material(
        color: Colors.transparent,
        child: Container(
          width: 450,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Настроить Мою волну',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 32),

              _buildSectionTitle('Под занятие'),
              _buildChips([
                _VibeItem('Просыпаюсь', 'activity:wake-up'),
                _VibeItem('В дороге', 'activity:road-trip'),
                _VibeItem('Работаю', 'activity:work-background'),
                _VibeItem('Тренируюсь', 'activity:workout'),
                _VibeItem('Засыпаю', 'activity:fall-asleep'),
              ], currentSeeds),

              const SizedBox(height: 32),
              _buildSectionTitle('По характеру'),
              Row(
                children: [
                  _CharacterCard(
                    label: 'Любимое',
                    icon: Icons.favorite,
                    color: Colors.red,
                    seed: 'personal:collection',
                    onSelected: onSelected,
                    isSelected: currentSeeds.contains('personal:collection'),
                  ),
                  const SizedBox(width: 12),
                  _CharacterCard(
                    label: 'Незнакомое',
                    icon: Icons.auto_awesome,
                    color: Colors.amber,
                    seed: 'personal:never-heard',
                    onSelected: onSelected,
                    isSelected: currentSeeds.contains('personal:never-heard'),
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

              const SizedBox(height: 32),
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
                _MoodItem('Спокойное', [Colors.cyan, Colors.teal], 'mood:calm'),
                _MoodItem('Грустное', [Colors.blue, Colors.indigo], 'mood:sad'),
              ], currentSeeds),

              const SizedBox(height: 32),
              _buildSectionTitle('По языку'),
              _buildChips([
                _VibeItem('Русский', 'local-language:russian'),
                _VibeItem('Иностранный', 'local-language:english'),
                _VibeItem('Без слов', 'local-language:instrumental'),
              ], currentSeeds),

              const SizedBox(height: 32),
              // Show the active station from the catalog if it's not one of the main ones
              if (currentSeeds.isNotEmpty &&
                  !currentSeeds.contains('user:onyourwave') &&
                  !_isMainSeed(currentSeeds.first))
                _buildActiveExtraStation(currentSeeds.first),

              Center(
                child: TextButton.icon(
                  onPressed: () async {
                    await showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: Colors.transparent,
                      isScrollControlled: true,
                      builder: (context) => const _AllStationsSheet(),
                    );
                  },
                  icon: const Icon(Icons.explore, color: Colors.white54),
                  label: const Text(
                    'Каталог всех станций',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          ),
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
        Watch((context) {
          final catsFuture = waveStationsSignal.value;
          var label = seed;
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
            padding: const EdgeInsets.only(bottom: 24),
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
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildChips(List<_VibeItem> items, List<String> currentSeeds) {
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

  Widget _buildMoods(List<_MoodItem> moods, List<String> currentSeeds) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: moods
          .map(
            (m) => _MoodCircle(
              mood: m,
              onSelected: onSelected,
              isSelected: currentSeeds.contains(m.seed),
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
    return FilterChip(
      selected: isSelected,
      label: Text(item.label),
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
          height: 110,
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
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.bold,
                  fontSize: 13,
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
            width: isSelected ? 66 : 60,
            height: isSelected ? 66 : 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 3)
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
                  blurRadius: isSelected ? 20 : 15,
                  spreadRadius: isSelected ? 4 : 2,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            mood.label,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
              fontSize: 12,
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
    return Watch((context) {
      final stationsFuture = waveStationsSignal.value;
      if (stationsFuture.isLoading) {
        return const Center(child: CircularProgressIndicator());
      }

      final currentSeeds = trackMetadataSignal().currentWaveSeeds;
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

      // Flatten categories and items into a single list for virtualization
      // and smooth scrolling (ListView.builder is truly lazy only when items are flat)
      final flatList = <dynamic>[];
      for (final cat in cats) {
        flatList
          ..add(cat.title) // Add Header
          ..addAll(cat.items); // Add individual Items
      }

      return Container(
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: const BoxDecoration(
          color: Color(0xFF181818),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
                        controller: _scrollController,
                        cacheExtent: 1000, // Pre-render to stabilize scrollbar
                        slivers: [
                          for (final cat in cats) ...[
                            // Category Header
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
                            // Wrap of Chips for this category
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
                                    return FilterChip(
                                      selected: isSelected,
                                      label: Text(item.label),
                                      onSelected: (_) {
                                        unawaited(WaveController.toggleStation(item.seed));
                                        Navigator.pop(context);
                                      },
                                      backgroundColor: Colors.white.withValues(
                                        alpha: 0.05,
                                      ),
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
                                        borderRadius: BorderRadius.circular(20),
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
      );
    });
  }
}
