import 'dart:async';

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

  void _showWaveSettings() {
    if (_overlayEntry != null) return;
    _overlayEntry = OverlayEntry(
      builder: (context) => _WaveOverlay(
        layerLink: _layerLink,
        onHover: ({required isHovered}) {
          _isHovered = isHovered;
          if (!isHovered) _hideWaveSettings();
        },
        onSelected: () {
          _isHovered = false;
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
    unawaited(Future.delayed(const Duration(milliseconds: 150), () {
      if (!_isHovered && mounted) {
        _overlayEntry?.remove();
        _overlayEntry = null;
      }
    }));
  }

  @override
  Widget build(BuildContext context) {
    final currentState = currentNavStateSignal.watch(context);
    final currentSection = currentState.section;
    final isHome = currentSection == AppSection.home;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: isHome
            ? Colors.black.withValues(alpha: 0.5)
            : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isHome ? 0.8 : 0.4),
            blurRadius: 30,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CompositedTransformTarget(
            link: _layerLink,
            child: MouseRegion(
              onEnter: (_) {
                _isHovered = true;
                _showWaveSettings();
              },
              onExit: (_) {
                _isHovered = false;
                _hideWaveSettings();
              },
              child: Watch((context) {
                final metadata = trackMetadataSignal.watch(context);
                final isWaveActive = metadata.currentWaveSeeds.isNotEmpty;
                final isPlaying = metadata.isPlaying;

                return IconButton(
                  onPressed: () {
                    if (isWaveActive) {
                      unawaited(PlaybackController.togglePlay());
                    } else {
                      unawaited(HomeController.startMyWave());
                    }
                  },
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    hoverColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
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
          ),
          const SizedBox(height: 12),
          _NavIcon(
            icon: Icons.home_rounded,
            isSelected: currentSection == AppSection.home,
            onTap: () => setSection(AppSection.home),
          ),
          _NavIcon(
            icon: Icons.search_rounded,
            isSelected: currentSection == AppSection.search,
            onTap: () => setSection(AppSection.search),
          ),
          _NavIcon(
            icon: Icons.library_music_rounded,
            isSelected:
                currentSection == AppSection.liked ||
                currentSection == AppSection.playlists,
            onTap: () => setSection(AppSection.liked),
          ),
          const SizedBox(height: 12),
          const _AccountButton(),
        ],
      ),
    );
  }
}

class _AccountButton extends StatelessWidget {
  const _AccountButton();

  @override
  Widget build(BuildContext context) {
    final account = accountSignal.watch(context);
    if (account == null) return const SizedBox();

    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (context) => _AccountMenuDialog(account: account),
      ),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: account.hasPlus
              ? LinearGradient(
                  colors: [Colors.purple, Colors.orange, Theme.of(context).colorScheme.primary],
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
    return Dialog(
      alignment: Alignment.centerLeft,
      insetPadding: const EdgeInsets.only(left: 96),
      backgroundColor: const Color(0xFF18181B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Container(
        width: 320,
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
                // Можно добавить переход на страницу профиля, если она будет
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
    return Positioned(
      width: 480,
      child: CompositedTransformFollower(
        link: widget.layerLink,
        showWhenUnlinked: false,
        offset: const Offset(80, -300),
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

  const _NavIcon({
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IconButton(
        onPressed: onTap,
        icon: Icon(
          icon,
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.white38,
          size: 28,
        ),
      ),
    );
  }
}
