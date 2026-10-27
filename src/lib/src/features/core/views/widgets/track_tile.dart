import 'dart:async';
import 'dart:io';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';
import 'package:yayma/src/features/core/views/widgets/app_cover.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/tab_visibility.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_actions.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';

class CommonTrackTile extends StatefulWidget {
  final String trackId;
  final String title;
  final String? version;
  final List<TrackArtistDto> artists;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget>? hoverActions;
  final VoidCallback? onTap;
  final VoidCallback? onTitleTap;
  final EdgeInsetsGeometry? contentPadding;
  final String? albumId;

  /// Cover for the sheet menu header on Android, when [leading] is
  /// not a cover (e.g. the track number in an album).
  final String? sheetCoverUrl;

  const CommonTrackTile({
    required this.trackId,
    required this.title,
    required this.artists,
    super.key,
    this.version,
    this.leading,
    this.trailing,
    this.hoverActions,
    this.onTap,
    this.onTitleTap,
    this.contentPadding,
    this.albumId,
    this.sheetCoverUrl,
  });

  @override
  State<CommonTrackTile> createState() => _CommonTrackTileState();
}

class _CommonTrackTileState extends State<CommonTrackTile> {
  final ValueNotifier<bool> _isHovered = ValueNotifier(false);
  final ValueNotifier<bool> _isPressed = ValueNotifier(false);
  final ValueNotifier<bool> _isMenuOpen = ValueNotifier(false);

  @override
  void dispose() {
    _isHovered.dispose();
    _isPressed.dispose();
    _isMenuOpen.dispose();
    super.dispose();
  }

  void _handleTap() {
    widget.onTap?.call();
  }

  Widget _adjustLeading(Widget leading, bool isNarrow) {
    if (isNarrow && leading is AppCover && leading.size == 64) {
      return AppCover(
        key: leading.key,
        coverUrl: leading.coverUrl ?? leading.url,
        url: leading.url,
        localUri: leading.localUri,
        size: 48,
        circle: leading.circle,
        heroTag: leading.heroTag,
        onTap: leading.onTap,
        borderRadius: leading.borderRadius,
        radius: leading.radius,
        shape: leading.shape,
        canExpand: leading.canExpand,
        hoverEnabled: leading.hoverEnabled,
        hoverScale: leading.hoverScale,
        fit: leading.fit,
        placeholderIcon: leading.placeholderIcon,
      );
    }
    return leading;
  }

  /// Actions shared with the full player menu.
  TrackContextActions get _trackActions {
    final leading = widget.leading;
    final cover = leading is AppCover ? leading : null;
    return TrackContextActions(
      trackId: widget.trackId,
      title: widget.title,
      version: widget.version,
      artists: widget.artists,
      albumId: widget.albumId,
      coverUrl: cover?.coverUrl ?? cover?.url ?? widget.sheetCoverUrl,
      localCoverUri: cover?.localUri,
    );
  }

  /// Open the bottom menu (sheet) with actions on a track.
  Future<void> _showTrackBottomSheet() => _trackActions.showSheet(context);

  Future<void> _handleMenuAction(String value) async {
    if (!mounted) return;
    _isHovered.value = false;
    await _trackActions.handle(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final isNarrow = context.isNarrow;

        final effectivePadding =
            widget.contentPadding ??
            EdgeInsets.symmetric(
              horizontal: isNarrow ? 8 : 12,
              vertical: isNarrow ? 4 : 8,
            );

        final menu = _TrackMenu(
          trackId: widget.trackId,
          albumId: widget.albumId,
          onOpen: () {
            _isMenuOpen.value = true;
            unawaited(refreshTrackPlaylistMembership(widget.trackId));
          },
          onClose: () {
            _isMenuOpen.value = false;
            _isHovered.value = false;
          },
          onSelected: _handleMenuAction,
        );

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _handleTap,
            onHover: (value) => _isHovered.value = value,
            onHighlightChanged: (value) => _isPressed.value = value,
            hoverColor: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.06),
            focusColor: Colors.transparent,
            highlightColor: Colors.transparent,
            splashColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _isHovered,
                _isMenuOpen,
                _isPressed,
              ]),
              builder: (context, _) {
                final isMenuOpen = _isMenuOpen.value;
                final isPressed = _isPressed.value;
                final showHighlighted = _isHovered.value || isMenuOpen;
                return AnimatedScale(
                  scale: isPressed ? 0.98 : 1.0,
                  duration: Duration(milliseconds: isPressed ? 80 : 180),
                  curve: isPressed ? Curves.easeOutCubic : Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: effectivePadding,
                    decoration: BoxDecoration(
                      color: isMenuOpen
                          ? Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      children: [
                        if (widget.leading != null) ...[
                          _LeadingPlayingBadge(
                            trackId: widget.trackId,
                            child: _adjustLeading(widget.leading!, isNarrow),
                          ),
                          SizedBox(width: isNarrow ? 12 : 16),
                        ],
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: _TrackTileTitle(
                                      trackId: widget.trackId,
                                      title: widget.title,
                                      version: widget.version,
                                      isNarrow: isNarrow,
                                      onTap: widget.onTitleTap,
                                    ),
                                  ),
                                  _TrackTileDownloadBadge(
                                    trackId: widget.trackId,
                                    isNarrow: isNarrow,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              ArtistNamesWidget(
                                artists: widget.artists,
                                fontSize: isNarrow ? 13 : 15,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: isNarrow ? 12 : 16),
                        _TrackTileActions(
                          showHighlighted: showHighlighted,
                          trailing: widget.trailing,
                          hoverActions: widget.hoverActions,
                          onShowSheet: _showTrackBottomSheet,
                          menu: menu,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Right side of a track row: the "more" button on Android, trailing widget
/// and hover actions with the menu on desktop.
class _TrackTileActions extends StatelessWidget {
  final bool showHighlighted;
  final Widget? trailing;
  final List<Widget>? hoverActions;
  final VoidCallback onShowSheet;
  final Widget menu;

  const _TrackTileActions({
    required this.showHighlighted,
    required this.onShowSheet,
    required this.menu,
    this.trailing,
    this.hoverActions,
  });

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return IconButton(
        icon: Icon(
          Icons.more_horiz_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        tooltip: 'Действия',
        onPressed: onShowSheet,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!showHighlighted && trailing != null) trailing!,
        if (showHighlighted) ...[...?hoverActions, menu],
      ],
    );
  }
}

/// Actions menu for a track: playlists, album, lyrics, link, wave, download.
class _TrackMenu extends StatelessWidget {
  final String trackId;
  final String? albumId;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  final ValueChanged<String> onSelected;

  const _TrackMenu({
    required this.trackId,
    required this.onOpen,
    required this.onClose,
    required this.onSelected,
    this.albumId,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // Menu content is built lazily here; no subscription while the
        // hosting tab is hidden.
        final playlists = visibleSignal(context, playlistsSignal);
        final membershipKinds =
            visibleSignal(context, trackPlaylistMembershipSignal)[trackId] ??
            const <int>{};
        return AppContextMenu<String>(
          onOpen: onOpen,
          onClose: onClose,
          onSelected: onSelected,
          items: [
            AppContextMenuItem(
              label: 'Добавить в плейлист',
              icon: Icons.playlist_add_rounded,
              subItems: () => [
                ...playlists.map(
                  (p) => AppContextMenuItem(
                    value: 'add_to_${p.kind}',
                    label: p.title,
                    icon: Icons.library_music_rounded,
                    isSelected: membershipKinds.contains(p.kind),
                    leading: p.coverUrl == null
                        ? null
                        : AppCover(
                            coverUrl: p.coverUrl,
                            url: p.coverUrl,
                            size: 40,
                          ),
                  ),
                ),
                const AppContextMenuItem(
                  value: 'create_playlist',
                  label: 'Создать новый плейлист',
                  icon: Icons.add_rounded,
                ),
              ],
            ),
            if (albumId != null)
              const AppContextMenuItem(
                value: 'go_to_album',
                label: 'Перейти к альбому',
                icon: Icons.album_rounded,
              ),
            const AppContextMenuItem(
              value: 'lyrics',
              label: 'Открыть текст',
              icon: Icons.lyrics_rounded,
            ),
            const AppContextMenuItem(
              value: 'copy_link',
              label: 'Скопировать ссылку',
              icon: Icons.link_rounded,
            ),
            const AppContextMenuItem(
              value: 'wave',
              label: 'Моя волна по треку',
              icon: Icons.waves_rounded,
            ),
            const AppContextMenuItem(
              value: 'about',
              label: 'О треке',
              icon: Icons.info_outline_rounded,
            ),
            AppContextMenuItem(
              label: 'Скачать',
              icon: Icons.download_rounded,
              subItems: () => [
                const AppContextMenuItem(
                  value: 'download_cache',
                  label: 'В кэш приложения',
                  icon: Icons.offline_bolt_rounded,
                ),
                const AppContextMenuItem(
                  value: 'download_files',
                  label: 'В отдельный файл',
                  icon: Icons.file_download_rounded,
                ),
              ],
            ),
            if (visibleSignal(
              context,
              downloadedTracksSignal,
            ).contains(trackId))
              const AppContextMenuItem(
                value: 'delete_downloaded',
                label: 'Удалить из загрузок',
                icon: Icons.remove_circle_outline_rounded,
              ),
          ],
          child: IconButton(
            icon: Icon(
              Icons.more_horiz_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onPressed: null,
            tooltip: 'Действия',
          ),
        );
      },
    );
  }
}

/// Title line of a track row: the title with its version appended, plus the
/// hover underline and the accent colour of the current track.
class _TrackTileTitle extends StatefulWidget {
  final String trackId;
  final String title;
  final String? version;
  final bool isNarrow;
  final VoidCallback? onTap;

  const _TrackTileTitle({
    required this.trackId,
    required this.title,
    required this.isNarrow,
    this.version,
    this.onTap,
  });

  @override
  State<_TrackTileTitle> createState() => _TrackTileTitleState();
}

class _TrackTileTitleState extends State<_TrackTileTitle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SignalBuilder(
          builder: (context) {
            // No subscription while the hosting tab is hidden.
            final isCurrent =
                visibleSignal(context, currentTrackIdSignal) == widget.trackId;
            return Text.rich(
              trackTitleSpan(
                context,
                title: widget.title,
                version: widget.version,
                versionFontSize: widget.isNarrow ? 12 : 14,
                style: TextStyle(
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.w400,
                  fontSize: widget.isNarrow ? 14 : 16,
                  decoration: _hovered && widget.onTap != null
                      ? TextDecoration.underline
                      : null,
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
      ),
    );
  }
}

/// Download state of the track, shown right after the title.
class _TrackTileDownloadBadge extends StatelessWidget {
  final String trackId;
  final bool isNarrow;

  const _TrackTileDownloadBadge({
    required this.trackId,
    required this.isNarrow,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // No subscription while the hosting tab is hidden.
        final isDownloading = visibleSignal(
          context,
          downloadingTracksSignal,
        ).contains(trackId);
        final isDownloaded = visibleSignal(
          context,
          downloadedTracksSignal,
        ).contains(trackId);
        if (!isDownloading && !isDownloaded) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: isDownloading
              ? M3ECircularWavyProgressIndicator(
                  strokeWidth: 2,
                  size: isNarrow ? 12 : 14,
                )
              : Icon(
                  Icons.download_done_rounded,
                  size: isNarrow ? 14 : 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
        );
      },
    );
  }
}

/// Badge over leading (usually the cover): visible only on the current track.
/// While playing — animated equalizer, while paused — static.
class _LeadingPlayingBadge extends StatelessWidget {
  final String trackId;
  final Widget child;

  const _LeadingPlayingBadge({required this.trackId, required this.child});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // No subscriptions while the hosting tab is hidden.
        final isCurrent =
            visibleSignal(context, currentTrackIdSignal) == trackId;
        if (!isCurrent) return child;
        final isPlaying = visibleSignal(context, isPlayingSignal);
        final scheme = Theme.of(context).colorScheme;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            Positioned(
              right: -6,
              bottom: -6,
              child: Tooltip(
                message: isPlaying ? 'Сейчас играет' : 'Текущий трек на паузе',
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.surface, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: TrackPlayingIndicator(
                    isPlaying: isPlaying,
                    height: 12,
                    color: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
