import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/utils/cover_tint.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Header data of the track context menu.
class TrackContextSheetHeader {
  final String title;
  final String? version;
  final List<TrackArtistDto> artists;
  final String? coverUrl;
  final Uri? localCoverUri;

  const TrackContextSheetHeader({
    required this.title,
    required this.artists,
    this.version,
    this.coverUrl,
    this.localCoverUri,
  });
}

class TrackSheetAction {
  final String? value;
  final String label;
  final IconData? icon;

  /// Custom leading widget (e.g. playlist cover); overrides [icon].
  final Widget? leading;
  final Color? color;

  /// Non-null: tapping this entry opens a follow-up sheet built with this
  /// builder instead of firing [value] directly. Called each time the sub
  /// sheet (re)builds, so it can return fresh options.
  final List<TrackSheetAction> Function()? subActions;
  final String? subSheetTitle;
  final bool isSelected;

  /// Keep the sheet open after the action fires (quick toggles like "like").
  final bool keepOpen;

  /// Called when the user opens the nested sheet.
  final VoidCallback? onSubSheetOpen;

  const TrackSheetAction({
    required this.label,
    this.icon,
    this.value,
    this.leading,
    this.color,
    this.subActions,
    this.subSheetTitle,
    this.onSubSheetOpen,
    this.isSelected = false,
    this.keepOpen = false,
  });
}

/// Bottom menu (sheet) with actions on a track (Android).
/// At the top — cover with title and track version, below — artists, then a
/// row of [quickActions] (icon + label), at the bottom — the rest of the
/// actions. Items with [TrackSheetAction.subActions] open a nested sheet.
///
/// [quickActions] is rebuilt on signal changes, so it can render live state
/// (e.g. a filled heart for a liked track).
///
/// [subSheetRebuildOn] is only forwarded to the nested sheets: bumping it
/// redraws their contents (e.g. fresh membership checkmarks), but does not
/// rebuild this top-level sheet.
Future<void> showTrackContextSheet(
  BuildContext context, {
  required TrackContextSheetHeader header,
  required List<TrackSheetAction> actions,
  required void Function(String value) onSelected,
  List<TrackSheetAction> Function()? quickActions,
  ValueListenable<int>? subSheetRebuildOn,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeader(header),
              if (quickActions != null)
                SignalBuilder(
                  builder: (context) {
                    final quick = quickActions();
                    if (quick.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final action in quick)
                            Expanded(
                              child: _QuickActionButton(
                                action,
                                onSelected,
                                subSheetRebuildOn: subSheetRebuildOn,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              Divider(
                height: 1,
                indent: 12,
                endIndent: 12,
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
              const SizedBox(height: 4),
              ...actions.map(
                (action) => _SheetActionTile(
                  action,
                  onSelected,
                  subSheetRebuildOn: subSheetRebuildOn,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Nested menu (sheet) — list of options with a title (Android).
/// [actionsBuilder] is called on every build: when [rebuildOn] changes
/// the list of items is rebuilt (fresh data, e.g. checkmarks).
Future<void> showTrackSubActionSheet(
  BuildContext context, {
  required String title,
  required List<TrackSheetAction> Function() actionsBuilder,
  required void Function(String value) onSelected,
  ValueListenable<int>? rebuildOn,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;

      final header = Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: Text(
          title,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

      final content = SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: ValueListenableBuilder<int>(
            valueListenable: rebuildOn ?? _dummyRebuildVersions,
            builder: (sheetContext, _, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  // The item closes the sheet itself (Navigator.pop in
                  // _SheetActionTile), so a second pop is NOT needed here —
                  // otherwise the router stack breaks.
                  ...actionsBuilder().map(
                    (action) => _SheetActionTile(
                      action,
                      onSelected,
                      subSheetRebuildOn: rebuildOn,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      return content;
    },
  );
}

/// Header of the sheet: the cover's own colours bloom behind it as slow,
/// drifting blobs (picked from the artwork, so every track gets its own hue),
/// while the cover and the text fade in.
class _SheetHeader extends StatefulWidget {
  final TrackContextSheetHeader header;

  const _SheetHeader(this.header);

  @override
  State<_SheetHeader> createState() => _SheetHeaderState();
}

class _SheetHeaderState extends State<_SheetHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.1, 1, curve: Curves.easeOut),
  );

  late final Animation<double> _coverScale = Tween<double>(
    begin: 0.9,
    end: 1,
  ).animate(_fade);

  List<Color> _tint = const [];
  bool _tintRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Needs MediaQuery for the same pixel preset the cover itself uses.
    if (!_tintRequested) {
      _tintRequested = true;
      unawaited(_loadTint());
    }
  }

  Future<void> _loadTint() async {
    final header = widget.header;
    final tint = await coverTint(
      coverUrl: header.coverUrl,
      localUri: header.localCoverUri,
      pixels: (96 * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    if (mounted && tint.isNotEmpty) setState(() => _tint = tint);
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final header = widget.header;

    return ClipRect(
      child: Stack(
        children: [
          if (_tint.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOut,
                  builder: (context, value, child) =>
                      Opacity(opacity: value, child: child),
                  child: _BreathingTint(colors: _tint),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            // Transition widgets drive this instead of an `AnimatedBuilder`
            // rebuilding the header: the cover and the text stay mounted
            // while the entrance plays.
            child: FadeTransition(
              opacity: _fade,
              child: Row(
                children: [
                  ScaleTransition(
                    scale: _coverScale,
                    alignment: Alignment.centerLeft,
                    child: AppCover(
                      coverUrl: header.coverUrl,
                      localUri: header.localCoverUri,
                      size: 96,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _fade,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            header.version == null
                                ? header.title
                                : '${header.title} ${header.version}',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          ArtistNamesWidget(
                            artists: header.artists,
                            // Close the sheet first, otherwise it stays
                            // on top of the opened artist page.
                            onArtistTap: (artistId) {
                              Navigator.of(context).pop();
                              navigateTo(AppSection.artist, artistId);
                            },
                          ),
                        ],
                      ),
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, 10 * (1 - _fade.value)),
                        child: child,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft radial blobs in the cover's colours drifting against each other.
/// Gradient-only, no image blur, so it repaints cheaply.
class _BreathingTint extends StatefulWidget {
  final List<Color> colors;

  const _BreathingTint({required this.colors});

  @override
  State<_BreathingTint> createState() => _BreathingTintState();
}

class _BreathingTintState extends State<_BreathingTint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  )..repeat(reverse: true);

  /// Built once: the gradients are static, only their positions change.
  late final List<Widget> _blobs = [
    for (final color in widget.colors)
      SizedBox(
        width: 210,
        height: 210,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: 0.5),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sheetColor =
        theme.bottomSheetTheme.modalBackgroundColor ??
        theme.bottomSheetTheme.backgroundColor ??
        scheme.surfaceContainerLow;

    return RepaintBoundary(
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final t = _controller.value * math.pi * 2;
                  return Stack(
                    children: [
                      for (var i = 0; i < _blobs.length; i++)
                        Align(
                          alignment: Alignment(
                            math.sin(t + i * 2.1) * 0.8,
                            -1 + math.cos(t * 0.7 + i * 1.9) * 0.5,
                          ),
                          child: _blobs[i],
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          // Fades the tint into the sheet instead of a ShaderMask
          // (no saveLayer per frame); same result on a solid background.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      sheetColor.withValues(alpha: 0),
                      sheetColor.withValues(alpha: 0),
                      sheetColor,
                    ],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final ValueListenable<int> _dummyRebuildVersions = ValueNotifier(0);

/// Runs a sheet action: opens its nested sheet, or closes the current one and
/// reports the value (unless the action opts to stay open).
void _runAction(
  BuildContext context,
  TrackSheetAction action,
  void Function(String value) onSelected,
  ValueListenable<int>? subSheetRebuildOn,
) {
  if (action.subActions != null) {
    unawaited(_openSubSheet(context, action, onSelected, subSheetRebuildOn));
    return;
  }
  final value = action.value;
  if (value == null) {
    assert(false, 'Действие «${action.label}» без value/subActions');
    return;
  }
  if (!action.keepOpen) Navigator.of(context).pop();
  onSelected(value);
}

Future<void> _openSubSheet(
  BuildContext context,
  TrackSheetAction action,
  void Function(String value) onSelected,
  ValueListenable<int>? subSheetRebuildOn,
) async {
  action.onSubSheetOpen?.call();
  // Close the current sheet first, then show the follow-up one.
  final navigator = Navigator.of(context)..pop();
  await showTrackSubActionSheet(
    navigator.context,
    title: action.subSheetTitle ?? action.label,
    // The builder is passed "as is": showTrackSubActionSheet calls it
    // on every rebuild (rebuildOn), otherwise the checkmarks won't update.
    actionsBuilder: action.subActions ?? (() => const []),
    rebuildOn: subSheetRebuildOn,
    onSelected: onSelected,
  );
}

/// Icon + label quick action in the row under the sheet header.
class _QuickActionButton extends StatelessWidget {
  final TrackSheetAction action;
  final void Function(String value) onSelected;

  /// Forwarded to the nested sheet, which rebuilds on every increment.
  final ValueListenable<int>? subSheetRebuildOn;

  const _QuickActionButton(
    this.action,
    this.onSelected, {
    this.subSheetRebuildOn,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: () =>
              _runAction(context, action, onSelected, subSheetRebuildOn),
          tooltip: action.label,
          icon: Icon(
            action.icon,
            size: 22,
            color: action.isSelected ? scheme.primary : action.color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          action.label,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SheetActionTile extends StatelessWidget {
  final TrackSheetAction action;
  final void Function(String value) onSelected;

  /// Forwarded to the nested sheet, which rebuilds on every increment.
  final ValueListenable<int>? subSheetRebuildOn;

  const _SheetActionTile(
    this.action,
    this.onSelected, {
    this.subSheetRebuildOn,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          leading: action.leading != null
              ? SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(child: action.leading),
                )
              : Icon(
                  action.icon,
                  size: 22,
                  color: action.color ?? scheme.onSurfaceVariant,
                ),
          title: Text(
            action.label,
            style: TextStyle(
              color: action.color ?? scheme.onSurface,
              fontSize: 18,
            ),
          ),
          trailing: action.isSelected
              ? Icon(Icons.check_rounded, size: 22, color: scheme.primary)
              : action.subActions != null
              ? Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: scheme.onSurfaceVariant,
                )
              : null,
          onTap: () =>
              _runAction(context, action, onSelected, subSheetRebuildOn),
        ),
      ),
    );
  }
}
