import 'dart:io';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/simple.dart' as simple;
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
import 'package:yayma/src/ui/yandex_id_view.dart';

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
      currentRootSignal.watch(context);
      final navState = currentNavStateSignal.watch(context);
      final isHome = navState.section == AppSection.home;
      
      final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
      final isCustomTitlebar = isDesktop && simple.isCustomTitlebarEnabledSync();
      
      final screenWidth = MediaQuery.sizeOf(context).width;
      final isNarrow = screenWidth < 600;

      return Scaffold(
        backgroundColor: Colors.black,
        body: PageStorage(
          bucket: _bucket,
          child: Stack(
            children: [
              // 1. Background (shader + blur)
              const Positioned.fill(child: BlurredCoverBackground()),
              const Positioned.fill(child: WaveBackground()),

              // 2. Dimming when leaving home or showing lyrics
              Watch((context) {
                final showLyrics = showLyricsSignal.watch(context);
                final hideOverlay = hideLyricsOverlaySignal.watch(context);
                final isDimmed = isHome
                    ? (showLyrics && !hideOverlay)
                    : true;

                return Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    color: isDimmed ? (isHome ? Colors.black54 : Colors.black87) : Colors.transparent,
                  ),
                );
              }),

              // 3. Content (set of independent stacks for each tab)
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(top: isCustomTitlebar ? 32.0 : 0),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Stack(
                          children: rootSections
                              .map((root) => _buildRootBucket(context, root))
                              .toList(),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: isNarrow ? 96 : 0,
                        child: _buildAnimatedPlayerBar(isHome),
                      ),
                    ],
                  ),
                ),
              ),

              // 4. Navigation
              Align(
                alignment: isNarrow ? Alignment.bottomCenter : Alignment.centerLeft,
                child: const FloatingNavBar(),
              ),

              // 5. Back button
              _FloatingBackButton(),

              // 6. Custom Titlebar
              if (isCustomTitlebar)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SizedBox(
                    height: 32,
                    child: WindowCaption(
                      brightness: Brightness.dark,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
            ],
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

      if (root == AppSection.account && !isVisible) {
        return const SizedBox.shrink();
      }

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
    return Watch((context) {
      final showLyrics = showLyricsSignal.watch(context);
      final shouldShowBar = !isHome || showLyrics;

      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        reverseDuration: const Duration(milliseconds: 500),
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
        child: shouldShowBar
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                key: ValueKey('player_bar_visible'),
                child: PlayerBar(),
              )
            : const SizedBox.shrink(key: ValueKey('player_bar_hidden')),
      );
    });
  }

  List<Widget> _buildWindowStack(List<NavState> stack) {
    return stack.asMap().entries.map((entry) {
      final index = entry.key;
      final state = entry.value;
      final isLast = index == stack.length - 1;
      final isHome = state.section == AppSection.home;

      // Keep only the current and previous screens in the tab stack
      final isDeeplyHidden = index < stack.length - 2;

      return Offstage(
        key: ValueKey('win_${state.section}_${state.id}_$index'),
        offstage: isDeeplyHidden,
        child: TickerMode(
          enabled: !isDeeplyHidden,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 500),
            opacity: isLast ? 1.0 : 0.0,
            curve: Curves.easeInOutCubic,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 500),
              offset: isLast
                  ? Offset.zero
                  : (isHome ? const Offset(0, -0.05) : Offset.zero),
              curve: Curves.easeOutCubic,
              child: IgnorePointer(
                ignoring: !isLast,
                child: _buildWindowContent(state, index),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildWindowContent(NavState state, int index) {
    return Watch((context) {
      final isHome = state.section == AppSection.home;
      final screenWidth = MediaQuery.sizeOf(context).width;
      final isNarrow = screenWidth < 600;

      // For the settings, do not use PageStorageKey to avoid saving state between visits.
      final key = state.section == AppSection.account
          ? ValueKey('account_$index')
          : PageStorageKey('scroll_${state.section}_${state.id}_$index');

      final child = KeyedSubtree(
        key: key,
        child: _mapSectionToWidget(state),
      );

      return Padding(
        padding: EdgeInsets.only(
          left: (isHome || isNarrow) ? 0 : 96,
          bottom: (isHome || !isNarrow) ? 0 : 96,
        ),
        child: child,
      );
    });
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
      case AppSection.yandexId:
        return const YandexIdView();
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
