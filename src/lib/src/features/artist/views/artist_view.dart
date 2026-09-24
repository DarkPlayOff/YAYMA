import 'dart:async';
import 'dart:io' show Platform;

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/horizontal_shelf.dart';
import 'package:yayma/src/features/core/views/widgets/media_card.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/track_elements.dart';
import 'package:yayma/src/features/core/views/widgets/track_tile.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';

class ArtistView extends StatefulWidget {
  final String? artistId;
  const ArtistView({super.key, this.artistId});

  @override
  State<ArtistView> createState() => _ArtistViewState();
}

class _ArtistViewState extends State<ArtistView> {
  final FlutterSignal<List<SimpleTrackDto>> _tracks =
      signal<List<SimpleTrackDto>>([]);
  final FlutterSignal<SimpleArtistDto?> _artist = signal<SimpleArtistDto?>(
    null,
  );
  final FlutterSignal<List<SimpleAlbumDto>> _albums =
      signal<List<SimpleAlbumDto>>([]);
  final FlutterSignal<bool> _isLoading = signal<bool>(false);
  final FlutterSignal<String?> _isError = signal<String?>(null);
  final FlutterSignal<int> _totalTracks = signal<int>(0);
  int _currentPage = 0;
  static const _pageSize = 30;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    unawaited(_loadInitial());
    unawaited(refreshLikedArtists());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 500 &&
        !_isLoading.value &&
        _tracks.value.length < _totalTracks.value) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadInitial() async {
    final id = widget.artistId;
    if (id == null) return;

    _isLoading.value = true;
    _isError.value = null;

    try {
      final details = await rust.getArtistDetails(
        ctx: appContextSignal.value!,
        artistId: id,
        page: 0,
        pageSize: _pageSize,
      );
      if (details != null) {
        _artist.value = SimpleArtistDto(
          id: details.id,
          name: details.name,
          coverUrl: details.coverUrl,
        );
        _tracks.value = details.tracks;
        _albums.value = details.albums;
        _totalTracks.value = details.totalTracks;
        _currentPage = 0;
      } else {
        _isError.value = 'Артист не найден';
      }
    } on Object catch (e) {
      _isError.value = e.toString();
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _loadMore() async {
    final id = widget.artistId;
    if (id == null) return;

    _isLoading.value = true;
    _currentPage++;

    try {
      final details = await rust.getArtistDetails(
        ctx: appContextSignal.value!,
        artistId: id,
        page: _currentPage,
        pageSize: _pageSize,
      );
      if (details != null) {
        _tracks.value = [..._tracks.value, ...details.tracks];
      }
    } on Object catch (e) {
      debugPrint('Error loading more tracks: $e');
    } finally {
      _isLoading.value = false;
    }
  }

  Future<void> _toggleArtistLike(SimpleArtistDto artist, bool isLiked) async {
    final success = isLiked
        ? await removeLikedArtistAction(artist.id)
        : await addLikedArtistAction(artist.id);

    if (!mounted) return;
    if (success) {
      final current = likedArtistsSignal.value;
      if (isLiked) {
        likedArtistsSignal.value = current
            .where((a) => a.id != artist.id)
            .toList();
      } else if (!current.any((a) => a.id == artist.id)) {
        likedArtistsSignal.value = [
          SimpleArtistDto(
            id: artist.id,
            name: artist.name,
            coverUrl: artist.coverUrl,
          ),
          ...current,
        ];
      }

      showAppSuccess(
        isLiked ? 'Исполнитель удалён из любимых' : 'Исполнитель добавлен в любимые',
      );
    } else {
      showAppError('Ошибка при обновлении любимых исполнителей');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.artistId == null) {
      return const Center(child: Text('Артист не выбран'));
    }

    return SignalBuilder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        if (_isError.value != null) {
          return CommonErrorWidget(error: _isError.value!);
        }

        final artist = _artist.value;
        if (artist == null && _isLoading.value) {
          return const CommonLoadingWidget();
        }

        if (artist == null) {
          return const Center(child: Text('Артист не найден'));
        }

        final tracks = _tracks.value;
        final albums = _albums.value;
        final isLiked = likedArtistsSignal.value.any(
          (likedArtist) => likedArtist.id == artist.id,
        );
        final isAndroid = Platform.isAndroid;

        return CommonDetailSliverLayout(
          controller: _scrollController,
          header: CommonDetailHeader(
            type: 'Артист',
            title: artist.name,
            coverUrl: artist.coverUrl,
            coverSize: 200,
            isCircle: true,
            actions: [
              if (isAndroid)
                IconButton(
                  onPressed: () => unawaited(
                    _toggleArtistLike(artist, isLiked),
                  ),
                  tooltip: isLiked ? 'В любимых' : 'В любимые',
                  icon: Icon(
                    isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    iconSize: 26,
                    backgroundColor: isLiked
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.1),
                    foregroundColor: isLiked ? cs.onPrimary : cs.onSurface,
                    side: isLiked
                        ? null
                        : BorderSide(color: cs.outlineVariant),
                  ),
                )
              else
                M3EButton.icon(
                  onPressed: () => unawaited(
                    _toggleArtistLike(artist, isLiked),
                  ),
                  icon: Icon(
                    isLiked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                  label: Text(isLiked ? 'В любимых' : 'В любимые'),
                  style: isLiked
                      ? M3EButtonStyle.filled
                      : M3EButtonStyle.outlined,
                  size: M3EButtonSize.md,
                  decoration: isLiked
                      ? null
                      : M3EButtonDecoration.styleFrom(
                          backgroundColor: cs.onSurface.withValues(
                            alpha: 0.1,
                          ),
                          foregroundColor: cs.onSurface,
                        ),
                ),
            ],
          ),
          slivers: [
            if (albums.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: CommonSectionTitle(
                  title: 'Альбомы',
                  padding: EdgeInsets.fromLTRB(
                    context.isNarrow ? 16 : 40,
                    24,
                    context.isNarrow ? 16 : 40,
                    16,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: HorizontalShelf(
                  // cover + title + subtitle + card paddings
                  height: (context.isNarrow ? 132.0 : 160.0) + 80,
                  padding: EdgeInsets.symmetric(
                    // 4/32 + 8 (internal card padding)
                    horizontal: context.isNarrow ? 4 : 32,
                  ),
                  itemCount: albums.length,
                  itemBuilder: (context, i) {
                    final album = albums[i];
                    return CommonMediaCard(
                      title: album.title,
                      subtitle: album.year?.toString(),
                      coverUrl: album.coverUrl,
                      size: context.isNarrow ? 132 : 160,
                      onTap: () => navigateTo(AppSection.album, album.id),
                    );
                  },
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: CommonSectionTitle(
                title: 'Популярные треки (${_totalTracks.value})',
                padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
              ),
            ),
            SliverM3ESegmentedList(
              haptic: M3EHapticFeedback.light,
              itemCount: tracks.length,
              color: Colors.transparent,
              padding: EdgeInsets.symmetric(
                horizontal: context.isNarrow ? 0 : 16,
                vertical: 4,
              ),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return CommonTrackTile(
                  trackId: track.id,
                  title: track.title,
                  version: track.version,
                  artists: track.artists,
                  albumId: track.albumId,
                  leading: TrackCover(
                    url: track.coverUrl,
                    size: 48,
                    borderRadius: 4,
                  ),
                  trailing: Text(
                    formatDuration(track.durationMs),
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                  onTap: () => PlaybackController.playTrack(track.id),
                  onTitleTap: () {
                    if (track.albumId != null) {
                      navigateTo(AppSection.album, track.albumId);
                    }
                  },
                );
              },
            ),
            if (_isLoading.value)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: M3ELoadingIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }
}
