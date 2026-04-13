import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/ui/album_view.dart';
import 'package:yayma/src/ui/artist_view.dart';
import 'package:yayma/src/ui/home_view.dart';
import 'package:yayma/src/ui/layout/background.dart';
import 'package:yayma/src/ui/layout/navigation_bar.dart';
import 'package:yayma/src/ui/layout/player_bar.dart';
import 'package:yayma/src/ui/library_view.dart';
import 'package:yayma/src/ui/playlist_view.dart';
import 'package:yayma/src/ui/search_view.dart';
import 'package:yayma/src/ui/settings_view.dart';

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  final PageStorageBucket _bucket = PageStorageBucket();

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final activeRoot = currentRootSignal.watch(context);
      final navState = currentNavStateSignal.watch(context);
      final isHome = navState.section == AppSection.home;

      return Scaffold(
        backgroundColor: Colors.black,
        body: PageStorage(
          bucket: _bucket,
          child: GlobalNotificationListener(
            child: Stack(
              children: [
                // 1. Фон (шейдер + размытие)
                const Positioned.fill(child: BlurredCoverBackground()),
                const Positioned.fill(child: WaveBackground()),

                // 2. Затемнение при уходе с главной
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    color: isHome ? Colors.transparent : Colors.black87,
                  ),
                ),

                // 3. Контент (набор независимых стеков для каждой вкладки)
                Positioned.fill(
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: rootSections
                              .map((root) => _buildRootBucket(context, root))
                              .toList(),
                        ),
                      ),
                      _buildAnimatedPlayerBar(isHome),
                    ],
                  ),
                ),

                // 4. Навигация (NavBar)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.only(left: 16),
                    child: FloatingNavBar(),
                  ),
                ),

                // 5. Кнопка "Назад"
                _FloatingBackButton(),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildRootBucket(BuildContext context, AppSection root) {
    return Watch((context) {
      final activeRoot = currentRootSignal.watch(context);
      final stack = rootStacksSignal.watch(context)[root] ?? [NavState(root)];
      final isVisible = activeRoot == root;

      return Offstage(
        offstage: !isVisible,
        child: TickerMode(
          enabled: isVisible,
          child: Stack(
            children: _buildWindowStack(stack),
          ),
        ),
      );
    });
  }

  Widget _buildAnimatedPlayerBar(bool isHome) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        reverseDuration: const Duration(milliseconds: 400),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final offsetAnimation = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(animation);
          return SlideTransition(
            position: offsetAnimation,
            child: child,
          );
        },
        child: !isHome
            ? const Padding(
                padding: EdgeInsets.only(left: 96),
                key: ValueKey('player_bar_visible'),
                child: PlayerBar(),
              )
            : const SizedBox.shrink(key: ValueKey('player_bar_hidden')),
      ),
    );
  }

  List<Widget> _buildWindowStack(List<NavState> stack) {
    return stack.asMap().entries.map((entry) {
      final index = entry.key;
      final state = entry.value;
      final isLast = index == stack.length - 1;

      // Оптимизация: оставляем только текущий и предыдущий экраны в стеке вкладки
      final isDeeplyHidden = index < stack.length - 2;

      return Offstage(
        key: ValueKey('win_${state.section}_${state.id}_$index'),
        offstage: isDeeplyHidden,
        child: TickerMode(
          enabled: !isDeeplyHidden,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: isLast ? 1.0 : 0.0,
            curve: Curves.easeInOut,
            child: IgnorePointer(
              ignoring: !isLast,
              child: _buildWindowContent(state, index),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildWindowContent(NavState state, int index) {
    final isRoot = state.section == AppSection.home;
    final child = KeyedSubtree(
      key: PageStorageKey('scroll_${state.section}_${state.id}_$index'),
      child: _mapSectionToWidget(state),
    );

    return isRoot
        ? child
        : Padding(
            padding: const EdgeInsets.only(left: 96),
            child: child,
          );
  }

  Widget _mapSectionToWidget(NavState state) {
    switch (state.section) {
      case AppSection.home:
        return const HomeView();
      case AppSection.search:
        return const SearchView();
      case AppSection.liked:
      case AppSection.playlists:
        return const LibraryView();
      case AppSection.album:
        return AlbumView(albumId: state.id);
      case AppSection.artist:
        return ArtistView(artistId: state.id);
      case AppSection.playlist:
        final parts = state.id?.split(':') ?? [];
        return PlaylistView(
          uid: parts.isNotEmpty ? parts[0] : null,
          kind: parts.length > 1 ? parts[1] : null,
        );
      case AppSection.wave:
        return const Center(
          child: Text('Волна', style: TextStyle(color: Colors.white24)),
        );
      case AppSection.account:
        return const SettingsView();
    }
  }
}

class _FloatingBackButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      if (!canGoBackSignal.value) return const SizedBox.shrink();

      return Positioned(
        top: 60,
        left: 24,
        child: IconButton(
          onPressed: goBack,
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xFF1E1E1E),
            hoverColor: Colors.white10,
            padding: const EdgeInsets.all(12),
            side: const BorderSide(color: Colors.white10),
          ),
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white70,
            size: 24,
          ),
        ),
      );
    });
  }
}
