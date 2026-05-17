import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/responsive.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';
import 'package:yayma/src/ui/widgets/track_tile.dart';

class LibraryView extends StatefulWidget {
  const LibraryView({super.key});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final currentSection = navStackSignal.value.last.section;
    final initialIndex = currentSection == AppSection.playlists ? 1 : 0;
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: initialIndex,
    );
    _searchController.text = librarySearchQuerySignal.value;
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(
      refreshLikedTracks(
        query: _searchController.text.isEmpty ? null : _searchController.text,
      ),
    );
    unawaited(refreshPlaylists());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    var isPublic = false;

    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: const Text(
              'Новый плейлист',
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Название',
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text(
                    'Публичный',
                    style: TextStyle(color: Colors.white70),
                  ),
                  value: isPublic,
                  onChanged: (val) => setState(() => isPublic = val),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (controller.text.isNotEmpty) {
                    final success = await createPlaylistAction(
                      controller.text,
                      isPublic: isPublic,
                    );
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    if (!success) {
                      showAppError('Ошибка при создании плейлиста');
                    } else {
                      showAppSuccess('Плейлист "${controller.text}" создан');
                    }
                  }
                },
                child: const Text('Создать'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            isNarrow ? 20 : 40,
            isNarrow ? 40 : 60,
            isNarrow ? 20 : 40,
            isNarrow ? 12 : 20,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Библиотека',
                  style: TextStyle(
                    fontSize: isNarrow ? 32 : 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -1,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              TextButton.icon(
                onPressed: () => _showCreatePlaylistDialog(context),
                icon: const Icon(Icons.add_rounded),
                label: isNarrow
                    ? const SizedBox.shrink()
                    : const Text('Создать плейлист'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  padding: EdgeInsets.symmetric(
                    horizontal: isNarrow ? 12 : 16,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: EdgeInsets.symmetric(horizontal: isNarrow ? 20 : 40),
          indicatorColor: Theme.of(context).colorScheme.primary,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white38,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Любимые треки'),
            Tab(text: 'Плейлисты'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _LikedTracksTab(searchController: _searchController),
              const _PlaylistsTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _LikedTracksTab extends StatelessWidget {
  final TextEditingController searchController;
  const _LikedTracksTab({required this.searchController});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    return Watch((context) {
      final tracks = likedTracksSignal.value;
      final query = librarySearchQuerySignal.value;
      final barColor = playerBarColorSignal.watch(context);
      final isHome = currentRootSignal.watch(context) == AppSection.home;
      final alpha = isHome ? 0.5 : 0.7;

      return Stack(
        children: [
          if (tracks.isEmpty)
            Center(
              child: Text(
                query.isEmpty ? 'Нет любимых треков' : 'Ничего не найдено',
                style: const TextStyle(color: Colors.white38),
              ),
            )
          else
            ListView.builder(
              padding: EdgeInsets.only(
                top: isNarrow ? 70 : 80,
                bottom: 140,
              ),
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                return CommonTrackTile(
                  trackId: track.id,
                  title: track.title,
                  version: track.version,
                  artists: track.artists,
                  leading: TrackCover(url: track.coverUrl),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: isNarrow ? 20 : 40,
                    vertical: 8,
                  ),
                  trailing: Text(
                    formatDuration(track.durationMs),
                    style: const TextStyle(color: Colors.white38),
                  ),
                  hoverActions: [
                    IconButton(
                      icon: Icon(
                        Icons.play_arrow_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      onPressed: () => unawaited(
                        PlaybackController.playLikedTrack(track.id),
                      ),
                    ),
                  ],
                  onTap: () =>
                      unawaited(PlaybackController.playLikedTrack(track.id)),
                  onTitleTap: () {
                    if (track.albumId != null) {
                      navigateTo(AppSection.album, track.albumId);
                    }
                  },
                );
              },
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.horizontalPadding,
                8,
                context.horizontalPadding,
                12,
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor.withValues(alpha: alpha),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: TextField(
                        controller: searchController,
                        onChanged: setLibrarySearchQuery,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Поиск в любимых треках...',
                          hintStyle: const TextStyle(color: Colors.white24),
                          prefixIcon: const Icon(
                            Icons.search,
                            color: Colors.white38,
                          ),
                          suffixIcon: searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear,
                                    color: Colors.white38,
                                  ),
                                  onPressed: () {
                                    searchController.clear();
                                    setLibrarySearchQuery('');
                                  },
                                )
                              : null,
                          filled: false,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    return Watch((context) {
      final playlists = playlistsSignal.value;

      if (playlists.isEmpty) {
        return const Center(
          child: Text(
            'Нет плейлистов',
            style: TextStyle(color: Colors.white38),
          ),
        );
      }

      return GridView.builder(
        padding: EdgeInsets.fromLTRB(
          isNarrow ? 20 : 40,
          isNarrow ? 20 : 40,
          isNarrow ? 20 : 40,
          140,
        ),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: isNarrow ? 180 : 200,
          mainAxisSpacing: isNarrow ? 16 : 24,
          crossAxisSpacing: isNarrow ? 16 : 24,
          childAspectRatio: isNarrow ? 0.7 : 0.75,
        ),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          return _PlaylistCard(playlist: playlist);
        },
      );
    });
  }
}

class _PlaylistCard extends StatefulWidget {
  final SimplePlaylistDto playlist;
  const _PlaylistCard({required this.playlist});

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  final ValueNotifier<bool> _isHovered = ValueNotifier(false);

  @override
  void dispose() {
    _isHovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;

    return MouseRegion(
      onEnter: (_) => _isHovered.value = true,
      onExit: (_) => _isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: _isHovered,
        builder: (context, hovered, _) {
          return GestureDetector(
            onTap: () => navigateTo(
              AppSection.playlist,
              '${playlist.uid}:${playlist.kind}',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: TrackCover(
                            url: playlist.coverUrl,
                            size: 200,
                            borderRadius: 16,
                          ),
                        ),
                      ),
                      if (hovered)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Center(
                              child: IconButton(
                                iconSize: 48,
                                icon: Icon(
                                  Icons.play_circle_filled_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                onPressed: () => unawaited(
                                  PlaybackController.playPlaylist(
                                    playlist.uid.toString(),
                                    playlist.kind,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  playlist.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${playlist.trackCount} треков',
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
