import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/providers/search_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/add_to_playlist_dialog.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/media_card.dart';
import 'package:yayma/src/ui/widgets/responsive.dart';
import 'package:yayma/src/ui/widgets/track_elements.dart';
import 'package:yayma/src/ui/widgets/track_tile.dart';

class SearchView extends StatefulWidget {
  const SearchView({super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.text = searchQuerySignal.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(builder: (context) {
      final searchResultsAsync = searchResultsSignal.value;
      final screenWidth = MediaQuery.sizeOf(context).width;
      final isNarrow = screenWidth < 600;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: isNarrow
                ? const EdgeInsets.fromLTRB(20, 16, 20, 8)
                : context.viewPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Поиск',
                  style: TextStyle(
                    fontSize: isNarrow ? 24 : 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -1,
                  ),
                ),
                if (!isNarrow) const SizedBox(height: 24),
                if (isNarrow) const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  onChanged: setSearchQuery,
                  style: TextStyle(
                    fontSize: isNarrow ? 18 : 24,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Треки, альбомы, артисты...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isNarrow ? 12 : 16,
                      ),
                      child: Icon(
                        Icons.search,
                        color: Colors.white54,
                        size: isNarrow ? 24 : 32,
                      ),
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(isNarrow ? 16 : 24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      vertical: isNarrow ? 16 : 24,
                      horizontal: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: searchResultsAsync.map(
              data: (results) {
                if (results == null) return const _EmptySearchState();
                if (results.tracks.isEmpty &&
                    results.albums.isEmpty &&
                    results.artists.isEmpty) {
                  return const Center(
                    child: Text(
                      'Ничего не найдено',
                      style: TextStyle(color: Colors.white38, fontSize: 18),
                    ),
                  );
                }
                return _SearchResults(results: results);
              },
              loading: () => const CommonLoadingWidget(),
              error: (Object e, StackTrace? _) =>
                  CommonErrorWidget(error: e.toString()),
            ),
          ),
        ],
      );
    });
  }
}

class _EmptySearchState extends StatelessWidget {
  const _EmptySearchState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.manage_search_rounded, size: 80, color: Colors.white10),
          SizedBox(height: 16),
          Text(
            'Начните вводить текст',
            style: TextStyle(color: Colors.white24, fontSize: 18),
          ),
        ],
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  final SearchResultsDto results;

  const _SearchResults({required this.results});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        if (results.artists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: CommonSectionTitle(title: 'Артисты')),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 180,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                ), // 32 + 8 (internal card padding) = 40
                itemCount: results.artists.length,
                itemBuilder: (context, i) =>
                    _ArtistSearchCard(artist: results.artists[i]),
              ),
            ),
          ),
        ],
        if (results.albums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: CommonSectionTitle(title: 'Альбомы')),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 240,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                ), // 32 + 8 = 40
                itemCount: results.albums.length,
                itemBuilder: (context, i) =>
                    _AlbumSearchCard(album: results.albums[i]),
              ),
            ),
          ),
        ],
        if (results.tracks.isNotEmpty) ...[
          const SliverToBoxAdapter(child: CommonSectionTitle(title: 'Треки')),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _TrackSearchTile(track: results.tracks[i]),
              childCount: results.tracks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 140)),
      ],
    );
  }
}

class _TrackSearchTile extends StatelessWidget {
  final SimpleTrackDto track;

  const _TrackSearchTile({required this.track});

  @override
  Widget build(BuildContext context) {
    return CommonTrackTile(
      trackId: track.id,
      title: track.title,
      version: track.version,
      artists: track.artists,
      albumId: track.albumId,
      leading: TrackCover(url: track.coverUrl),
      trailing: Text(
        formatDuration(track.durationMs),
        style: const TextStyle(color: Colors.white38),
      ),
      hoverActions: [
        IconButton(
          icon: const Icon(Icons.add_rounded, color: Colors.white38),
          tooltip: 'Добавить в плейлист',
          onPressed: () => AddToPlaylistDialog.show(context, track),
        ),
        IconButton(
          icon: Icon(
            Icons.play_arrow_rounded,
            color: Theme.of(context).colorScheme.primary,
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
  }
}

class _AlbumSearchCard extends StatelessWidget {
  final SimpleAlbumDto album;

  const _AlbumSearchCard({required this.album});

  @override
  Widget build(BuildContext context) {
    return CommonMediaCard(
      title: album.title,
      artists: album.artists,
      coverUrl: album.coverUrl,
      onTap: () => navigateTo(AppSection.album, album.id),
    );
  }
}

class _ArtistSearchCard extends StatelessWidget {
  final SimpleArtistDto artist;

  const _ArtistSearchCard({required this.artist});

  @override
  Widget build(BuildContext context) {
    return CommonMediaCard(
      title: artist.name,
      coverUrl: artist.coverUrl,
      isCircle: true,
      size: 140,
      onTap: () => navigateTo(AppSection.artist, artist.id),
    );
  }
}
