import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/smooth_scroll.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/playback/providers/wave_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Opens the "Моя волна" settings sheet (stations, moods, seeds).
Future<void> showWaveSettingsSheet(BuildContext context) {
  return showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      snap: true,
      builder: (context, scrollController) => WaveSettingsPanel(
        onSelected: () => Navigator.pop(context),
        scrollController: scrollController,
      ),
    ),
  );
}

class WaveSettingsPanel extends StatelessWidget {
  final VoidCallback onSelected;
  final ScrollController? scrollController;
  const WaveSettingsPanel({
    required this.onSelected,
    this.scrollController,
    super.key,
  });
  static const List<_VibeItem> _vibes = [
    _VibeItem('Просыпаюсь', 'activity:wake-up'),
    _VibeItem('В дороге', 'activity:road-trip'),
    _VibeItem('Работаю', 'activity:work-background'),
    _VibeItem('Тренируюсь', 'activity:workout'),
    _VibeItem('Засыпаю', 'activity:fall-asleep'),
  ];

  static const List<_VibeItem> _languages = [
    _VibeItem('Русский', 'local-language:russian'),
    _VibeItem('Иностранный', 'local-language:english'),
    _VibeItem('Без слов', 'local-language:instrumental'),
  ];

  static const List<_MoodItem> _moods = [
    _MoodItem('Бодрое', [Colors.orange, Colors.deepOrange], 'mood:energetic'),
    _MoodItem('Весёлое', [Colors.lightGreen, Colors.lime], 'mood:happy'),
    _MoodItem('Спокойное', [Colors.cyan, Colors.teal], 'mood:calm'),
    _MoodItem('Грустное', [Colors.blue, Colors.indigo], 'mood:sad'),
  ];

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final currentSeeds = currentWaveSeedsSignal();

        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(context, currentSeeds),
                    const SizedBox(height: 24),
                    _buildSectionTitle(context, 'Под занятие'),
                    _buildChips(context, _vibes, currentSeeds),
                    const SizedBox(height: 24),
                    _buildSectionTitle(context, 'По характеру'),
                    _buildCharacters(context, currentSeeds),
                    const SizedBox(height: 24),
                    _buildSectionTitle(context, 'Под настроение'),
                    _buildMoods(_moods, currentSeeds),
                    const SizedBox(height: 24),
                    _buildSectionTitle(context, 'По языку'),
                    _buildChips(context, _languages, currentSeeds),
                    const SizedBox(height: 24),
                    if (currentSeeds.isNotEmpty &&
                        !currentSeeds.contains('user:onyourwave') &&
                        !_isMainSeed(currentSeeds.first))
                      _buildActiveExtraStation(context, currentSeeds.first),
                  ],
                ),
              ),
              if (context.isNarrow) _buildStartButton(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, List<String> currentSeeds) {
    final iconColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final canReset =
        currentSeeds.isNotEmpty && !currentSeeds.contains('user:onyourwave');

    return Row(
      children: [
        Expanded(
          child: Text(
            'Настроить Мою волну',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
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
          child: canReset
              ? _HeaderIcon(
                  icon: Icons.refresh,
                  color: iconColor,
                  onTap: () => unawaited(WaveController.resetStations()),
                )
              : null,
        ),
        SizedBox(
          width: 40,
          height: 40,
          child: _HeaderIcon(
            icon: Icons.explore,
            color: iconColor,
            onTap: () => showAppBottomSheet<void>(
              context: context,
              builder: (context) => const _AllStationsSheet(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCharacters(BuildContext context, List<String> currentSeeds) {
    return Row(
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
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          seed: 'personal:hits',
          onSelected: onSelected,
          isSelected: currentSeeds.contains('personal:hits'),
        ),
      ],
    );
  }

  Widget _buildStartButton(BuildContext context) {
    return Positioned(
      right: 24,
      bottom: 32,
      child: M3EFloatingActionButton(
        onPressed: () {
          unawaited(WaveController.startMyWave());
          onSelected();
        },
        containerColor: Theme.of(context).colorScheme.primary,
        contentColor: Colors.black,
        elevation: 8,
        child: const Icon(Icons.play_arrow_rounded, size: 28),
      ),
    );
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

  Widget _buildActiveExtraStation(BuildContext context, String seed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(context, 'Активный режим'),
        SignalBuilder(
          builder: (context) {
            final catsFuture = waveStationsSignal.value;
            var label = seed;

            if (seed.startsWith('track:')) {
              // Display hint is everything after the second ':'.
              // indexOf-based so titles containing ':' don't break parsing.
              final first = seed.indexOf(':');
              final second = first >= 0 ? seed.indexOf(':', first + 1) : -1;
              if (second >= 0 && second + 1 < seed.length) {
                label = seed.substring(second + 1);
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
          },
        ),
      ],
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
  const _VibeItem(this.label, this.seed);
}

class _MoodItem {
  final String label;
  final List<Color> colors;
  final String seed;
  const _MoodItem(this.label, this.colors, this.seed);
}

/// Square tap target with a plain icon, used in the sheet header.
class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _HeaderIcon({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
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
        constraints: BoxConstraints(
          maxWidth: maxLabelWidth > 0 ? maxLabelWidth : 100,
        ),
        child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      onSelected: (_) {
        unawaited(WaveController.toggleStation(item.seed));
      },
      backgroundColor: Theme.of(
        context,
      ).colorScheme.onSurface.withValues(alpha: 0.05),
      selectedColor: Theme.of(
        context,
      ).colorScheme.onSurface.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected
            ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: isSelected
          ? BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.24),
            )
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
                ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1)
                : Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.3)
                  : Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
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
                  color: isSelected
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurfaceVariant,
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
                  ? Border.all(
                      color: Theme.of(context).colorScheme.onSurface,
                      width: 2,
                    )
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
              color: isSelected
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
  final _scrollController = SmoothScrollController(debugLabel: 'stations');

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final stationsFuture = waveStationsSignal.value;
        if (stationsFuture.isLoading) {
          return const Center(child: M3ELoadingIndicator());
        }

        final currentSeeds = currentWaveSeedsSignal();
        final query = _searchQuery().toLowerCase();
        final cats = _filterCategories(stationsFuture.value ?? const [], query);

        return Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(context),
                _buildSearchField(context),
                Expanded(
                  child: _buildStationList(context, cats, currentSeeds, query),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Keeps only station categories that still have a matching item.
  List<StationCategoryDto> _filterCategories(
    List<StationCategoryDto> cats,
    String query,
  ) {
    if (query.isEmpty) return cats;
    return cats
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

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Row(
        children: [
          Text(
            'Каталог станций',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.close,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: TextField(
        controller: _controller,
        onChanged: (v) => _searchQuery.value = v,
        style: TextStyle(color: cs.onSurface),
        decoration: InputDecoration(
          hintText: 'Поиск по жанрам, настроениям...',
          hintStyle: TextStyle(
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          prefixIcon: Icon(
            Icons.search,
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          filled: true,
          fillColor: cs.onSurface.withValues(alpha: 0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  Widget _buildStationList(
    BuildContext context,
    List<StationCategoryDto> cats,
    List<String> currentSeeds,
    String query,
  ) {
    if (cats.isEmpty && query.isNotEmpty) {
      return Center(
        child: Text(
          'Ничего не найдено',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final maxLabelWidth = MediaQuery.sizeOf(context).width - 48 - 40;

    return Scrollbar(
      controller: _scrollController,
      child: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
        controller: _scrollController,
        slivers: [
          for (final cat in cats) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              sliver: SliverToBoxAdapter(
                child: Text(
                  cat.title.toUpperCase(),
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in cat.items)
                      _buildStationChip(
                        context,
                        item,
                        currentSeeds.contains(item.seed),
                        maxLabelWidth,
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
        ],
      ),
    );
  }

  Widget _buildStationChip(
    BuildContext context,
    StationItemDto item,
    bool isSelected,
    double maxLabelWidth,
  ) {
    final cs = Theme.of(context).colorScheme;
    return FilterChip(
      selected: isSelected,
      label: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxLabelWidth > 0 ? maxLabelWidth : 100,
        ),
        child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      onSelected: (_) {
        unawaited(WaveController.toggleStation(item.seed));
        Navigator.pop(context);
      },
      backgroundColor: cs.onSurface.withValues(alpha: 0.05),
      selectedColor: cs.onSurface.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected ? cs.onSurface : cs.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
        fontSize: 12,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: isSelected
          ? BorderSide(color: cs.onSurface.withValues(alpha: 0.24))
          : BorderSide.none,
      showCheckmark: false,
    );
  }
}
