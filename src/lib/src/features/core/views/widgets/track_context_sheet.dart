import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
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
  });
}

/// Bottom menu (sheet) with actions on a track (Android).
/// At the top — cover with title and track version, below — artists,
/// at the bottom — action buttons. Items with [TrackSheetAction.subActions]
/// open a nested sheet.
///
/// [subSheetRebuildOn] is only forwarded to the nested sheets: bumping it
/// redraws their contents (e.g. fresh membership checkmarks), but does not
/// rebuild this top-level sheet.
Future<void> showTrackContextSheet(
  BuildContext context, {
  required TrackContextSheetHeader header,
  required List<TrackSheetAction> actions,
  required void Function(String value) onSelected,
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    AppCover(
                      coverUrl: header.coverUrl,
                      localUri: header.localCoverUri,
                      size: 96,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
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
                          ArtistNamesWidget(artists: header.artists),
                        ],
                      ),
                    ),
                  ],
                ),
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

final ValueListenable<int> _dummyRebuildVersions = ValueNotifier(0);

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

  Future<void> _openSubSheet(BuildContext context) async {
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
          onTap: () {
            if (action.subActions != null) {
              unawaited(_openSubSheet(context));
              return;
            }
            final value = action.value;
            if (value == null) {
              assert(false, 'Действие «${action.label}» без value/subActions');
              return;
            }
            Navigator.of(context).pop();
            onSelected(value);
          },
        ),
      ),
    );
  }
}
