import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/media_card.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';
import 'package:yayma/src/ui/widgets/track_tile.dart';

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

  @override
  Widget build(BuildContext context) {
    if (widget.artistId == null) {
      return const Center(child: Text('Артист не выбран'));
    }

    return SignalBuilder(
      builder: (context) {
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

        return CommonDetailSliverLayout(
          controller: _scrollController,
          header: CommonDetailHeader(
            type: 'Артист',
            title: artist.name,
            coverUrl: artist.coverUrl,
            coverSize: 200,
            isCircle: true,
          ),
          slivers: [
            if (albums.isNotEmpty) ...[
              const SliverToBoxAdapter(
                child: CommonSectionTitle(
                  title: 'Альбомы',
                  padding: EdgeInsets.fromLTRB(40, 24, 40, 16),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 240,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                    ), // 32 + 8 (internal card padding) = 40
                    itemCount: albums.length,
                    itemBuilder: (context, i) {
                      final album = albums[i];
                      return CommonMediaCard(
                        title: album.title,
                        subtitle: album.year?.toString(),
                        coverUrl: album.coverUrl,
                        onTap: () => navigateTo(AppSection.album, album.id),
                      );
                    },
                  ),
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: CommonSectionTitle(
                title: 'Популярные треки (${_totalTracks.value})',
                padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
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
                    style: const TextStyle(color: Colors.white38),
                  ),
                  hoverActions: [
                    IconButton(
                      icon: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white54,
                      ),
                      onPressed: () => PlaybackController.playTrack(track.id),
                    ),
                  ],
                  onTap: () => PlaybackController.playTrack(track.id),
                  onTitleTap: () {
                    if (track.albumId != null) {
                      navigateTo(AppSection.album, track.albumId);
                    }
                  },
                );
              }, childCount: tracks.length),
            ),
            if (_isLoading.value)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }
}
