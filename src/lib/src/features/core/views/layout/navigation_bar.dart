import 'dart:async';
import 'dart:io';

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/init.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/auth/views/yandex_id_view.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/playback/providers/wave_provider.dart';
import 'package:yayma/src/features/playback/views/wave_view.dart';
import 'package:yayma/src/rust/api/models.dart';

class FloatingNavBar extends StatefulWidget {
  const FloatingNavBar({super.key});
  @override
  State<FloatingNavBar> createState() => _FloatingNavBarState();
}

class _FloatingNavBarState extends State<FloatingNavBar>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _showWaveTimer;
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
    return SignalBuilder(
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        final currentState = currentNavStateSignal.value;
        final currentSection = currentState.section;
        final isHome = currentSection == AppSection.home;
        final isAutoHideEnabled =
            !Platform.isAndroid && autoHideNavbarSignal.value;
        final isDesktop =
            Platform.isWindows || Platform.isLinux || Platform.isMacOS;
        final barColor = playerBarColorSignal.value;

        final isVisible =
            !isHome ||
            !isAutoHideEnabled ||
            _isNavbarHovered ||
            _isHovered ||
            _isAccountMenuOpen;
        final isNarrow = context.isNarrow;
        // Edge-to-edge: app draws behind the Android system navigation bar,
        // so lift the floating navbar above the 3-button/gesture bar.
        // viewPadding stays stable when the keyboard opens.
        final systemBottom = MediaQuery.viewPaddingOf(context).bottom;

        // The revealed label shares the bar with the icon slots (56 each) and
        // the bar hugs its content, so cap the label or the row overflows on a
        // small phone: 48 bar margins + 24 bar padding + 16 label gap.
        final slots = 3 + (isDesktop ? 1 : 0);
        final labelMaxWidth = isNarrow
            ? MediaQuery.sizeOf(context).width - 48 - 24 - slots * 56 - 16
            : 0.0;

        final children = [
          if (isDesktop)
            MouseRegion(
              onEnter: (_) {
                setState(() {
                  _isHovered = true;
                });
                _showWaveTimer?.cancel();
                _showWaveTimer = Timer(
                  const Duration(milliseconds: 200),
                  _showWaveSettings,
                );
              },
              onExit: (_) {
                _showWaveTimer?.cancel();
                _showWaveTimer = null;
                setState(() {
                  _isHovered = false;
                });
                _hideWaveSettings();
              },
              child: SignalBuilder(
                builder: (context) {
                  final isWaveActive = currentWaveSeedsSignal().isNotEmpty;
                  final isPlaying = isPlayingSignal();

                  return IconButton(
                    onPressed: () {
                      if (isWaveActive) {
                        unawaited(PlaybackController.togglePlay());
                      } else {
                        unawaited(WaveController.startMyWave());
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
                },
              ),
            ),
          if (isDesktop) const SizedBox(height: 12),
          if (!Platform.isAndroid)
            _NavIcon(
              icon: Icons.home_rounded,
              label: 'Главная',
              maxLabelWidth: labelMaxWidth,
              isSelected: currentSection == AppSection.home,
              onTap: () => setSection(AppSection.home),
              isNarrow: isNarrow,
            ),
          _NavIcon(
            icon: Icons.search_rounded,
            label: 'Поиск',
            maxLabelWidth: labelMaxWidth,
            isSelected: currentSection == AppSection.search,
            onTap: () => setSection(AppSection.search),
            isNarrow: isNarrow,
          ),
          _NavIcon(
            icon: Icons.library_music_rounded,
            label: 'Библиотека',
            maxLabelWidth: labelMaxWidth,
            isSelected:
                currentSection == AppSection.liked ||
                currentSection == AppSection.playlists,
            onTap: () => setSection(AppSection.liked),
            isNarrow: isNarrow,
          ),
          if (isDesktop) const SizedBox(height: 12),
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
                ? EdgeInsets.only(
                    bottom: 12 + systemBottom,
                    left: 24,
                    right: 24,
                  )
                : const EdgeInsets.only(
                    left: 16,
                    right: 48,
                    top: 48,
                    bottom: 48,
                  ),
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
                    width: isNarrow ? null : 64,
                    height: isNarrow ? 56 : null,
                    padding: EdgeInsets.symmetric(
                      vertical: isNarrow ? 0 : 12,
                      horizontal: isNarrow ? 12 : 0,
                    ),
                    decoration: BoxDecoration(
                      color: barColor,
                      borderRadius: BorderRadius.circular(AppRadius.xxxl),
                      border: Border.all(
                        color: colorScheme.onSurface.withValues(alpha: 0.1),
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
        );
      },
    );
  }

  @override
  void dispose() {
    _showWaveTimer?.cancel();
    _showWaveTimer = null;
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }
}

class _AccountButton extends SignalWidget {
  final VoidCallback onOpened;
  final VoidCallback onClosed;

  const _AccountButton({required this.onOpened, required this.onClosed});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final account = accountSignal.value;
    if (account == null) return const SizedBox();

    return InkWell(
      onTap: () async {
        onOpened();
        if (Platform.isAndroid) {
          await showAppBottomSheet<void>(
            context: context,
            builder: (context) => _AccountMenuContent(account: account),
          );
        } else {
          await showDialog<void>(
            context: context,
            barrierColor: Colors.black54,
            builder: (context) => _AccountMenuDialog(account: account),
          );
        }
        onClosed();
      },
      borderRadius: BorderRadius.circular(AppRadius.lg),
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
          border: account.hasPlus
              ? null
              : Border.all(color: cs.onSurface.withValues(alpha: 0.1)),
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
                    errorWidget: Icon(
                      Icons.person_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                  )
                : Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
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
    final isNarrow = context.isNarrow;

    return Dialog(
      alignment: isNarrow ? Alignment.bottomCenter : Alignment.centerLeft,
      insetPadding: isNarrow
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
          : const EdgeInsets.only(left: 96),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
      ),
      child: SizedBox(
        width: isNarrow ? double.infinity : 320,
        child: _AccountMenuContent(account: account),
      ),
    );
  }
}

/// Avatar header + account actions. Shared by the desktop dialog and the
/// Android sheet so both stay in sync.
class _AccountMenuContent extends StatelessWidget {
  final UserAccountDto account;

  const _AccountMenuContent({required this.account});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
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
                      : Border.all(color: cs.onSurface.withValues(alpha: 0.1)),
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
                            errorWidget: Icon(
                              Icons.person_rounded,
                              size: 32,
                              color: cs.onSurfaceVariant,
                            ),
                          )
                        : Icon(
                            Icons.person_rounded,
                            size: 32,
                            color: cs.onSurfaceVariant,
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
                      account.displayName ?? account.fullName ?? account.login,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      account.login,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close, color: cs.onSurfaceVariant, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _MenuTile(
            icon: Icons.badge_outlined,
            title: 'Управление аккаунтом',
            onTap: () {
              Navigator.pop(context);
              if (Platform.isAndroid) {
                Navigator.push<YandexIdView>(
                  context,
                  MaterialPageRoute<YandexIdView>(
                    fullscreenDialog: true,
                    builder: (_) => const YandexIdView(fullscreen: true),
                  ),
                );
              } else {
                setSection(AppSection.yandexId);
              }
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

          Divider(color: cs.onSurface.withValues(alpha: 0.1), height: 40),

          _MenuTile(
            icon: Icons.logout_rounded,
            title: 'Выйти из аккаунта',
            onTap: () {
              unawaited(AppInit.logout());
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  const _MenuTile({required this.icon, required this.title, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: [
            Icon(icon, color: cs.onSurface, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 15, color: cs.onSurface),
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
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = context.isNarrow;

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
                  borderRadius: BorderRadius.circular(AppRadius.xxl),
                  side: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                  ),
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

class _NavIcon extends StatefulWidget {
  final IconData icon;
  final String label;
  final double maxLabelWidth;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isNarrow;

  const _NavIcon({
    required this.icon,
    required this.label,
    required this.maxLabelWidth,
    required this.isSelected,
    required this.onTap,
    this.isNarrow = false,
  });

  @override
  State<_NavIcon> createState() => _NavIconState();
}

class _NavIconState extends State<_NavIcon> with TickerProviderStateMixin {
  // Material 3 Expressive motion tokens, same split as Compose: size and
  // position run on the spatial spring (it overshoots), colour and alpha on a
  // critically damped one (they must not). See ExpressiveMotionTokens.
  static const _spatialSpring = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 31.2, // 2 * 0.8 * sqrt(380)
  );
  static const _effectsSpring = SpringDescription(
    mass: 1,
    stiffness: 1600,
    damping: 80, // 2 * 1.0 * sqrt(1600)
  );

  late final _spatial = AnimationController.unbounded(
    vsync: this,
    value: widget.isSelected ? 1 : 0,
  );
  late final _effects = AnimationController.unbounded(
    vsync: this,
    value: widget.isSelected ? 1 : 0,
  );
  late final _progress = Listenable.merge([_spatial, _effects]);

  void _settle(AnimationController controller, SpringDescription spring) {
    final target = widget.isSelected ? 1.0 : 0.0;
    // Interrupting keeps the current velocity, like animate*AsState does.
    unawaited(
      controller
          .animateWith(
            SpringSimulation(
              spring,
              controller.value,
              target,
              controller.velocity,
            ),
          )
          // A spring only approaches the target; land exactly, as Compose does.
          .whenComplete(() {
            if (!controller.isAnimating) controller.value = target;
          }),
    );
  }

  @override
  void didUpdateWidget(_NavIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSelected == widget.isSelected) return;
    _settle(_spatial, _spatialSpring);
    _settle(_effects, _effectsSpring);
  }

  @override
  void dispose() {
    _spatial.dispose();
    _effects.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The flying label is the Android bottom bar treatment; the desktop rail
    // (and narrow desktop windows) stay icon-only.
    final labelsInline =
        widget.isNarrow && Theme.of(context).platform == TargetPlatform.android;
    final pill = AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        // Layout stops at the target so the hugging bar cannot overflow; the
        // spatial spring's overshoot stays visible in the shape.
        final t = _spatial.value.clamp(0.0, 1.0);
        final e = _effects.value.clamp(0.0, 1.0);
        final color = Color.lerp(
          scheme.onSurface.withValues(alpha: 0.38),
          scheme.primary,
          e,
        )!;
        final iconButton = SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            onPressed: widget.onTap,
            // On the phone the pill itself is the touch feedback; the ink
            // splash would paint a second, mismatched highlight over it.
            style: labelsInline
                ? IconButton.styleFrom(
                    splashFactory: NoSplash.splashFactory,
                    overlayColor: Colors.transparent,
                  )
                : null,
            icon: Icon(widget.icon, color: color, size: 28),
          ),
        );
        return Container(
          width: widget.isNarrow ? null : 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.18 * e),
            // 24 is half the pill height, i.e. a full capsule: AppRadius.full
            // would saturate on the first frame and snap.
            borderRadius: BorderRadius.circular(14 + 10 * _spatial.value),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.35 * e),
            ),
          ),
          child: labelsInline
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    iconButton,
                    Flexible(
                      // Always in the tree so it can slide back in: Compose
                      // never fades this label, it only reveals it.
                      child: ClipRect(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          widthFactor: t,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: widget.maxLabelWidth,
                              ),
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: color,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : iconButton,
        );
      },
    );

    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: widget.isNarrow ? 0 : 4,
        horizontal: widget.isNarrow ? 4 : 0,
      ),
      child: widget.isNarrow
          ? pill
          : Transform.scale(scale: 1 + 0.12 * _spatial.value, child: pill),
    );
  }
}
