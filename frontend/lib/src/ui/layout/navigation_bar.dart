import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/home_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/wave_view.dart';
import 'package:yayma/src/ui/widgets/rust_cached_image.dart';

class FloatingNavBar extends StatefulWidget {
  const FloatingNavBar({super.key});
  @override
  State<FloatingNavBar> createState() => _FloatingNavBarState();
}

class _FloatingNavBarState extends State<FloatingNavBar>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _isHovered = false;
  bool _isNavbarHovered = false;
  bool _isAccountMenuOpen = false;

  void _showWaveSettings() {
    if (_overlayEntry != null) return;
    _overlayEntry = OverlayEntry(
      builder: (context) => _WaveOverlay(
        layerLink: _layerLink,
        onHover: ({required isHovered}) {
          setState(() {
            _isHovered = isHovered;
          });
          if (!isHovered) _hideWaveSettings();
        },
        onSelected: () {
          setState(() {
            _isHovered = false;
          });
          _hideWaveSettings(immediate: true);
        },
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _hideWaveSettings({bool immediate = false}) {
    if (immediate) {
      _overlayEntry?.remove();
      _overlayEntry = null;
      return;
    }
    unawaited(
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!_isHovered && mounted) {
          _overlayEntry?.remove();
          _overlayEntry = null;
          if (!_isNavbarHovered) setState(() {});
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentState = currentNavStateSignal.watch(context);
    final currentSection = currentState.section;
    final isHome = currentSection == AppSection.home;
    final isAutoHideEnabled = autoHideNavbarSignal.watch(context);
    final barColor = playerBarColorSignal.watch(context);

    final isVisible =
        !isHome ||
        !isAutoHideEnabled ||
        _isNavbarHovered ||
        _isHovered ||
        _isAccountMenuOpen;
    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    final alpha = isHome ? 0.5 : 0.7;

    final children = [
      if (!isNarrow)
        MouseRegion(
          onEnter: (_) {
            setState(() {
              _isHovered = true;
            });
            _showWaveSettings();
          },
          onExit: (_) {
            setState(() {
              _isHovered = false;
            });
            _hideWaveSettings();
          },
          child: Watch((context) {
            final isWaveActive = currentWaveSeedsSignal().isNotEmpty;
            final isPlaying = isPlayingSignal();

            return IconButton(
              onPressed: () {
                if (isWaveActive) {
                  unawaited(PlaybackController.togglePlay());
                } else {
                  unawaited(HomeController.startMyWave());
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.1),
                hoverColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.2),
              ),
              icon: Icon(
                isWaveActive && isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
              ),
            );
          }),
        ),
      if (!isNarrow)
        SizedBox(height: isNarrow ? 0 : 12, width: isNarrow ? 12 : 0),
      _NavIcon(
        icon: Icons.home_rounded,
        isSelected: currentSection == AppSection.home,
        onTap: () => setSection(AppSection.home),
        isNarrow: isNarrow,
      ),
      _NavIcon(
        icon: Icons.search_rounded,
        isSelected: currentSection == AppSection.search,
        onTap: () => setSection(AppSection.search),
        isNarrow: isNarrow,
      ),
      _NavIcon(
        icon: Icons.library_music_rounded,
        isSelected:
            currentSection == AppSection.liked ||
            currentSection == AppSection.playlists,
        onTap: () => setSection(AppSection.liked),
        isNarrow: isNarrow,
      ),
      SizedBox(height: isNarrow ? 0 : 12, width: isNarrow ? 12 : 0),
      _AccountButton(
        onOpened: () => setState(() => _isAccountMenuOpen = true),
        onClosed: () => setState(() => _isAccountMenuOpen = false),
      ),
    ];

    return MouseRegion(
      opaque: false,
      onEnter: (_) => setState(() => _isNavbarHovered = true),
      onExit: (_) => setState(() => _isNavbarHovered = false),
      child: Padding(
        padding: isNarrow
            ? const EdgeInsets.only(bottom: 12, left: 24, right: 24)
            : const EdgeInsets.only(left: 16, right: 48, top: 48, bottom: 48),
        child: AnimatedSlide(
          offset: isVisible
              ? Offset.zero
              : (isNarrow ? const Offset(0, 1.5) : const Offset(-1.5, 0)),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: isVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: CompositedTransformTarget(
              link: _layerLink,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isHome ? 0.8 : 0.4),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: isHome ? 0 : 3,
                      sigmaY: isHome ? 0 : 3,
                    ),
                    child: Container(
                      width: isNarrow ? null : 64,
                      height: isNarrow ? 64 : null,
                      padding: EdgeInsets.symmetric(
                        vertical: isNarrow ? 0 : 12,
                        horizontal: isNarrow ? 12 : 0,
                      ),
                      decoration: BoxDecoration(
                        color: barColor.withValues(alpha: alpha),
                        borderRadius: BorderRadius.circular(32),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: isNarrow
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: children,
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: children,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountButton extends StatelessWidget {
  final VoidCallback onOpened;
  final VoidCallback onClosed;

  const _AccountButton({required this.onOpened, required this.onClosed});

  @override
  Widget build(BuildContext context) {
    final account = accountSignal.watch(context);
    if (account == null) return const SizedBox();

    return InkWell(
      onTap: () async {
        onOpened();
        await showDialog<void>(
          context: context,
          barrierColor: Colors.black54,
          builder: (context) => _AccountMenuDialog(account: account),
        );
        onClosed();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: account.hasPlus
              ? LinearGradient(
                  colors: [
                    Colors.purple,
                    Colors.orange,
                    Theme.of(context).colorScheme.primary,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          border: account.hasPlus ? null : Border.all(color: Colors.white10),
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: const BoxDecoration(
            color: Colors.black,
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: account.avatarUrl != null
                ? RustCachedImage(
                    imageUrl: account.avatarUrl,
                    width: 36,
                    height: 36,
                    errorWidget: const Icon(
                      Icons.person_rounded,
                      size: 20,
                      color: Colors.white70,
                    ),
                  )
                : const Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: Colors.white70,
                  ),
          ),
        ),
      ),
    );
  }
}

class _AccountMenuDialog extends StatelessWidget {
  final UserAccountDto account;

  const _AccountMenuDialog({required this.account});

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    return Dialog(
      alignment: isNarrow ? Alignment.bottomCenter : Alignment.centerLeft,
      insetPadding: isNarrow
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
          : const EdgeInsets.only(left: 96),
      backgroundColor: const Color(0xFF18181B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Container(
        width: isNarrow ? double.infinity : 320,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: account.hasPlus
                        ? LinearGradient(
                            colors: [
                              Colors.purple,
                              Colors.orange,
                              Theme.of(context).colorScheme.primary,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    border: account.hasPlus
                        ? null
                        : Border.all(color: Colors.white10),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: account.avatarUrl != null
                          ? RustCachedImage(
                              imageUrl: account.avatarUrl,
                              width: 64,
                              height: 64,
                              errorWidget: const Icon(
                                Icons.person_rounded,
                                size: 32,
                                color: Colors.white70,
                              ),
                            )
                          : const Icon(
                              Icons.person_rounded,
                              size: 32,
                              color: Colors.white70,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        account.displayName ??
                            account.fullName ??
                            account.login,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        account.login,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _MenuTile(
              icon: Icons.badge_outlined,
              title: 'Управление аккаунтом',
              onTap: () {
                Navigator.pop(context);
                setSection(AppSection.yandexId);
              },
            ),
            _MenuTile(
              icon: Icons.settings_outlined,
              title: 'Настройки',
              onTap: () {
                Navigator.pop(context);
                setSection(AppSection.account);
              },
            ),

            const Divider(color: Colors.white10, height: 40),

            _MenuTile(
              icon: Icons.logout_rounded,
              title: 'Выйти из аккаунта',
              onTap: () {
                unawaited(logout());
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  const _MenuTile({
    required this.icon,
    required this.title,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 15, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveOverlay extends StatefulWidget {
  final LayerLink layerLink;
  final void Function({required bool isHovered}) onHover;
  final VoidCallback onSelected;
  const _WaveOverlay({
    required this.layerLink,
    required this.onHover,
    required this.onSelected,
  });
  @override
  State<_WaveOverlay> createState() => _WaveOverlayState();
}

class _WaveOverlayState extends State<_WaveOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    unawaited(_anim.forward());
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    return Positioned(
      width: isNarrow ? screenWidth - 48 : 480,
      child: CompositedTransformFollower(
        link: widget.layerLink,
        showWhenUnlinked: false,
        targetAnchor: isNarrow ? Alignment.topCenter : Alignment.centerRight,
        followerAnchor: isNarrow
            ? Alignment.bottomCenter
            : Alignment.centerLeft,
        offset: isNarrow ? const Offset(0, -24) : const Offset(32, 0),
        child: MouseRegion(
          onEnter: (_) => widget.onHover(isHovered: true),
          onExit: (_) => widget.onHover(isHovered: false),
          child: ScaleTransition(
            scale: CurvedAnimation(parent: _anim, curve: Curves.easeOutBack),
            child: FadeTransition(
              opacity: _anim,
              child: Card(
                elevation: 24,
                color: const Color(0xFF1A1A1E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: const BorderSide(color: Colors.white10),
                ),
                child: WaveSettingsPanel(onSelected: widget.onSelected),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isNarrow;

  const _NavIcon({
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.isNarrow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: isNarrow ? 0 : 4,
        horizontal: isNarrow ? 4 : 0,
      ),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(
          icon,
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.white38,
          size: 28,
        ),
      ),
    );
  }
}
