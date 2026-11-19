import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PredictiveBackEvent;
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/features/album/views/album_view.dart';
import 'package:yayma/src/features/artist/views/artist_view.dart';
import 'package:yayma/src/features/auth/views/yandex_id_view.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/views/layout/background.dart';
import 'package:yayma/src/features/core/views/layout/mobile_full_player.dart';
import 'package:yayma/src/features/core/views/layout/navigation_bar.dart';
import 'package:yayma/src/features/core/views/layout/player_bar.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/tab_slide.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/home/views/home_view.dart';
import 'package:yayma/src/features/library/views/library_view.dart';
import 'package:yayma/src/features/library/views/playlist_view.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/search/views/search_view.dart';
import 'package:yayma/src/features/settings/views/settings_view.dart';

class AppLayout extends StatefulWidget {
  const AppLayout({super.key});

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final PageStorageBucket _bucket = PageStorageBucket();

  /// Which way the last tab switch went, for [TabSlide]. Read from the same
  /// build that flips the active root, so the leaving tab gets the same value.
  AppSection? _lastRoot;
  int _tabDirection = 1;

  /// Predictive back gesture progress, 0 at rest and 1 when the screen is gone.
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  NavState? _backScreen;
  NavState? _backUnder;
  int _backToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _back.dispose();
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // A sheet or pushed page above the app gets the gesture first, and so does
    // the full player, which drives its own collapse while it is open. Only
    // the root tab keeps the system back behaviour.
    // Navigator.of does not subscribe to route changes, unlike ModalRoute.of,
    // which would rebuild the whole layout on every sheet open and close.
    if (Navigator.of(context).canPop()) return false;
    if (!canGoBackSignal.value || mobileFullPlayerOpenSignal.value) {
      return false;
    }
    _backToken++;
    _backScreen = currentNavStateSignal.value;
    final stack = navStackSignal.value;
    _backUnder = stack[stack.length - 2];
    _back.value = 0;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    _back.value = backEvent.progress;
  }

  @override
  void handleCommitBackGesture() {
    final token = _backToken;
    unawaited(
      _back.animateTo(1, curve: Curves.easeOut).then((_) {
        goBack();
        // Keep the leaving screen shrunk while its own fade-out runs.
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (!mounted || token != _backToken) return;
          _backScreen = null;
          _backUnder = null;
          _back.value = 0;
        });
      }),
    );
  }

  @override
  void handleCancelBackGesture() {
    _back.animateTo(0, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final activeRoot = currentRootSignal();
        if (_lastRoot != activeRoot) {
          final from = rootSections.indexOf(_lastRoot ?? activeRoot);
          final to = rootSections.indexOf(activeRoot);
          if (from >= 0 && to >= 0 && from != to) {
            _tabDirection = to > from ? 1 : -1;
          }
          _lastRoot = activeRoot;
        }
        final navState = currentNavStateSignal();
        final isHome = navState.section == AppSection.home;

        final isDesktop =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        final isCustomTitlebar = isDesktop && customTitlebarSignal.value;

        // Use the touch layout for all Android form factors, including
        // tablets. A large Android screen must not select the desktop navbar.
        final isNarrow = context.isNarrow;

        return PopScope(
          canPop: !canGoBackSignal.value,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            if (canGoBackSignal.value) {
              goBack();
            }
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: PageStorage(
              bucket: _bucket,
              child: Stack(
                children: [
                  ..._buildBackground(),
                  _buildDimOverlay(isHome),
                  Positioned.fill(
                    child: SafeArea(
                      top: !isCustomTitlebar,
                      bottom: false,
                      child: Stack(
                        children: [
                          _buildContentLayer(
                            isHome: isHome,
                            isNarrow: isNarrow,
                            isCustomTitlebar: isCustomTitlebar,
                          ),
                          _buildNavigation(),
                          // Back button, and on desktop a refresh button
                          // because pull-to-refresh is not reachable with a
                          // mouse.
                          _FloatingBackButton(),
                          const _FloatingRefreshButton(),
                          if (isCustomTitlebar)
                            // Not const: WindowCaption holds a Finalizable
                            // field, and the incremental compiler then fails
                            // with "A const constructor can't have a body"
                            // (dart-lang/sdk#64487).
                            // ignore: prefer_const_constructors
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              // dart-lang/sdk#64487 above
                              // ignore: prefer_const_constructors
                              child: SizedBox(
                                height: 32,
                                // dart-lang/sdk#64487 above
                                // ignore: prefer_const_constructors
                                child: WindowCaption(
                                  brightness: Brightness.dark,
                                  backgroundColor: Colors.transparent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  _buildFullPlayerOverlay(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Material gradient on Android, blurred cover elsewhere, plus the shader.
  List<Widget> _buildBackground() {
    return [
      Positioned.fill(
        child: Platform.isAndroid
            ? const MaterialGradientBackground()
            : const BlurredCoverBackground(),
      ),
      if (!Platform.isAndroid) const Positioned.fill(child: WaveBackground()),
    ];
  }

  /// Dimming when leaving home or showing lyrics — held off while lyrics are
  /// still loading or came back empty, so nothing is shown over a darkened
  /// background in either case.
  Widget _buildDimOverlay(bool isHome) {
    return Positioned.fill(
      child: SignalBuilder(
        builder: (context) {
          final showLyrics = showLyricsSignal.value;
          final hideOverlay = hideLyricsOverlaySignal.value;
          final suppressDim = lyricsSuppressDimSignal.value;
          final dimForLyrics = showLyrics && !hideOverlay && !suppressDim;
          final isDimmed = Platform.isAndroid
              ? dimForLyrics
              : !isHome || dimForLyrics;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            color: isDimmed
                ? (isHome
                      ? Colors.black54
                      : Colors.black.withValues(alpha: 0.6))
                : Colors.transparent,
          );
        },
      ),
    );
  }

  /// Tabs plus the floating player bar above them.
  Widget _buildContentLayer({
    required bool isHome,
    required bool isNarrow,
    required bool isCustomTitlebar,
  }) {
    // Edge-to-edge: Flutter draws behind the Android system navigation bar, so
    // floating UI must sit above it manually. viewPadding (not padding) stays
    // stable when the keyboard opens.
    final systemBottom = MediaQuery.viewPaddingOf(context).bottom;

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(top: isCustomTitlebar ? 32.0 : 0),
        child: Stack(
          children: [
            // Independent stacks per tab, so each keeps its own scroll state.
            Positioned.fill(
              child: Stack(
                children: rootSections
                    .map(
                      (root) => _RootBucket(
                        root: root,
                        direction: _tabDirection,
                        back: _back,
                        backScreen: () => _backScreen,
                        backUnder: () => _backUnder,
                      ),
                    )
                    .toList(),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              // Floating player sits above the floating navbar on narrow
              // layouts, plus the Android system navigation inset.
              bottom:
                  ((isNarrow && !(Platform.isAndroid && showLyricsSignal.value))
                      ? 80.0
                      : 0.0) +
                  systemBottom,
              // While the full player covers the app, the bar keeps painting
              // behind it. Unmount it on Android instead.
              child: ValueListenableBuilder<double>(
                valueListenable: mobileFullPlayerProgress,
                builder: (context, progress, child) {
                  if (Platform.isAndroid && progress > 0.999) {
                    return const SizedBox.shrink();
                  }
                  return child!;
                },
                child: _AnimatedPlayerBar(isHome: isHome),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    return SignalBuilder(
      builder: (context) {
        final showLyrics = showLyricsSignal.value;
        final isAndroid = Platform.isAndroid;
        if (isAndroid && showLyrics) {
          return const SizedBox.shrink();
        }
        return Align(
          alignment: context.isNarrow
              ? Alignment.bottomCenter
              : Alignment.centerLeft,
          child: ValueListenableBuilder<double>(
            valueListenable: mobileFullPlayerProgress,
            builder: (context, progress, child) {
              if (Platform.isAndroid && progress > 0.999) {
                return const SizedBox.shrink();
              }
              final hiddenAt = progress.clamp(0.0, 1.0);
              // Fully faded: keep it out of the tree instead of painting a
              // transparent copy.
              if (hiddenAt >= 1) {
                return const SizedBox.shrink();
              }
              return IgnorePointer(
                ignoring: hiddenAt > 0,
                child: Opacity(
                  opacity: 1 - hiddenAt,
                  child: Transform.translate(
                    offset: Offset(0, 120 * hiddenAt),
                    child: child,
                  ),
                ),
              );
            },
            child: const FloatingNavBar(),
          ),
        );
      },
    );
  }

  Widget _buildFullPlayerOverlay() {
    return Positioned.fill(
      child: SignalBuilder(
        builder: (context) {
          if (!mobileFullPlayerOpenSignal.value) {
            return const SizedBox.shrink();
          }
          final origin = mobileFullPlayerOrigin.value;
          if (origin == null) return const SizedBox.shrink();
          return RepaintBoundary(
            child: MobileFullPlayer(
              plateRect: origin.plateRect,
              coverRect: origin.coverRect,
              controller: mobileFullPlayerController,
            ),
          );
        },
      ),
    );
  }
}

class _RootBucket extends StatelessWidget {
  final AppSection root;
  final int direction;
  final Animation<double> back;
  final NavState? Function() backScreen;
  final NavState? Function() backUnder;

  const _RootBucket({
    required this.root,
    required this.direction,
    required this.back,
    required this.backScreen,
    required this.backUnder,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final activeRoot = currentRootSignal.value;
        final stack = rootStacksSignal.value[root] ?? [NavState(root)];
        final isVisible = activeRoot == root;

        if (root == AppSection.account && !isVisible) {
          return const SizedBox.shrink();
        }

        return TabVisibility(
          isVisible: isVisible,
          child: TabSlide(
            isVisible: isVisible,
            direction: direction,
            child: Stack(children: _buildWindowStack(stack)),
          ),
        );
      },
    );
  }

  List<Widget> _buildWindowStack(List<NavState> stack) {
    // The tab root stays built forever (switching tabs keeps its state), plus
    // at most two screens pushed on top of it. Anything deeper needs more than
    // two back presses and would otherwise stay mounted - rebuilding on every
    // signal tick - for the life of the tab.
    final firstPushed = stack.length > 2 ? stack.length - 2 : 1;
    return stack
        .asMap()
        .entries
        .where((entry) => entry.key == 0 || entry.key >= firstPushed)
        .map((entry) {
          final index = entry.key;
          final state = entry.value;
          final isLast = index == stack.length - 1;
          final isHome = state.section == AppSection.home;

          // Keyed by destination, not stack position, so pushing a screen
          // keeps the previous one's state (scroll offset) instead of
          // rebuilding it from scratch.
          // Own fade instead of AnimatedOpacity, so a back gesture can also
          // raise the screen underneath while its target stays at 0.
          return TweenAnimationBuilder<double>(
            key: ValueKey('win_${state.section}_${state.id}'),
            tween: Tween(begin: isLast ? 1.0 : 0.0, end: isLast ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOutCubic,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 500),
              offset: isLast
                  ? Offset.zero
                  : (isHome ? const Offset(0, -0.05) : const Offset(0.03, 0)),
              curve: Curves.easeOutCubic,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 500),
                scale: isLast ? 1.0 : 0.98,
                curve: Curves.easeOutCubic,
                child: IgnorePointer(
                  ignoring: !isLast,
                  child: _WindowContent(state: state),
                ),
              ),
            ),
            builder: (context, visible, child) => AnimatedBuilder(
              animation: back,
              child: child,
              builder: (context, child) {
                // The leaving screen shrinks and fades out with the finger, and
                // the one beneath it fades in to full opacity on commit.
                final leaving = backScreen() == state ? back.value : 0.0;
                final revealed = backUnder() == state ? back.value : 0.0;
                final shown = visible * (1 - leaving);
                return Transform.scale(
                  scale: 1 - 0.1 * leaving,
                  child: Opacity(
                    opacity: shown > revealed ? shown : revealed,
                    child: child,
                  ),
                );
              },
            ),
          );
        })
        .toList();
  }
}

class _AnimatedPlayerBar extends StatelessWidget {
  final bool isHome;

  const _AnimatedPlayerBar({required this.isHome});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final showLyrics = showLyricsSignal.value;
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
            final opacityAnimation = Platform.isAndroid
                ? Tween<double>(begin: 0, end: 1).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: const Interval(0, 0.6, curve: Curves.easeIn),
                    ),
                  )
                : animation;
            return SlideTransition(
              position: offsetAnimation,
              child: FadeTransition(opacity: opacityAnimation, child: child),
            );
          },
          child: shouldShowBar
              ? const PlayerBar(key: ValueKey('player_bar_visible'))
              : const SizedBox.shrink(key: ValueKey('player_bar_hidden')),
        );
      },
    );
  }
}

class _WindowContent extends StatelessWidget {
  final NavState state;

  const _WindowContent({required this.state});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isHome = state.section == AppSection.home;
        final showLyrics = showLyricsSignal.value;
        final isNarrow = context.isNarrow;

        // Bottom padding calculation to avoid overlap with PlayerBar and NavBar
        // We only apply it to the browser (yandexId) and settings (account) to prevent them from being covered,
        // while other views keep scrolling to the very bottom.
        final hasPlayerBar = !isHome || showLyrics;

        double bottomPadding = 0;
        if (state.section == AppSection.yandexId ||
            state.section == AppSection.account) {
          if (isNarrow) {
            bottomPadding = hasPlayerBar ? 180 : 96;
          } else {
            bottomPadding = hasPlayerBar ? 116 : 0;
          }
          // Keep webview/settings content above the Android system buttons.
          bottomPadding += MediaQuery.viewPaddingOf(context).bottom;
        } else if (isHome && isNarrow) {
          // Home is centered non-scrollable content: its bottom row
          // (wave settings, repeat, quality) must stay above the floating
          // navbar. Navbar top sits at 56 (height) + 12 (gap) +
          // systemBottom above the screen bottom, plus a small gap.
          final navbarVisible = !(Platform.isAndroid && showLyrics);
          if (navbarVisible) {
            bottomPadding = 80 + MediaQuery.viewPaddingOf(context).bottom;
          }
        }

        final key = state.section == AppSection.account
            ? ValueKey('account_${state.section}')
            : PageStorageKey('scroll_${state.section}_${state.id}');

        final child = KeyedSubtree(
          key: key,
          child: _mapSectionToWidget(context, state),
        );

        return Padding(
          padding: EdgeInsets.only(
            left: (isHome || isNarrow) ? 0 : 96,
            bottom: bottomPadding,
          ),
          child: child,
        );
      },
    );
  }

  Widget _mapSectionToWidget(BuildContext context, NavState state) {
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
        return Center(
          child: Text(
            'Волна',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
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
    return SignalBuilder(
      builder: (context) {
        final canGoBack = canGoBackSignal.value;

        return Positioned(
          top: 60,
          left: 24,
          child: IgnorePointer(
            ignoring: !canGoBack,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              opacity: canGoBack ? 1 : 0,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                scale: canGoBack ? 1 : 0.6,
                child: ExcludeFocus(
                  excluding: !canGoBack,
                  child: IconButton(
                    onPressed: goBack,
                    style: IconButton.styleFrom(
                      backgroundColor: Color.lerp(
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                        Colors.black,
                        0.4,
                      ),
                      hoverColor: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.1),
                      padding: const EdgeInsets.all(12),
                      side: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.1),
                      ),
                    ),
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FloatingRefreshButton extends StatefulWidget {
  const _FloatingRefreshButton();

  @override
  State<_FloatingRefreshButton> createState() => _FloatingRefreshButtonState();
}

class _FloatingRefreshButtonState extends State<_FloatingRefreshButton> {
  static const Set<AppSection> _refreshable = {
    AppSection.liked,
    AppSection.playlists,
    AppSection.album,
    AppSection.artist,
    AppSection.playlist,
    AppSection.search,
  };

  bool _spinning = false;

  Future<void> _onRefresh() async {
    if (_spinning) return;
    setState(() => _spinning = true);
    try {
      requestGlobalRefresh();
      // Minimum spinner time: the views themselves show
      // their own loading indicators.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
    } finally {
      if (mounted) setState(() => _spinning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mobile has pull-to-refresh, so the button is not needed there.
    if (Platform.isAndroid) return const SizedBox.shrink();
    return SignalBuilder(
      builder: (context) {
        if (!_refreshable.contains(currentNavStateSignal.value.section)) {
          return const SizedBox.shrink();
        }
        // Level with the page title (titlebar 32 + page padding 40). With the
        // back button it moves below it, animated.
        return AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          top: canGoBackSignal.value ? 120.0 : 72.0,
          left: 24,
          child: IconButton(
            onPressed: _spinning ? null : _onRefresh,
            style: IconButton.styleFrom(
              backgroundColor: Color.lerp(
                Theme.of(context).colorScheme.surfaceContainerHighest,
                Colors.black,
                0.4,
              ),
              hoverColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.1),
              padding: const EdgeInsets.all(12),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.1),
              ),
            ),
            icon: _spinning
                ? M3ECircularWavyProgressIndicator(
                    size: 24,
                    strokeWidth: 2.5,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : Icon(
                    Icons.refresh_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 24,
                    semanticLabel: 'Обновить',
                  ),
          ),
        );
      },
    );
  }
}
