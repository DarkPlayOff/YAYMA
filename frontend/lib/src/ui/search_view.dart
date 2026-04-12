import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/providers/search_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/add_to_playlist_dialog.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';
import 'package:yayma/src/ui/widgets/media_card.dart';
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
    final searchResultsAsync = searchResultsSignal.watch(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 60, 40, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Поиск',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                onChanged: setSearchQuery,
                style: const TextStyle(fontSize: 24, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Треки, альбомы, артисты...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Icon(Icons.search, color: Colors.white54, size: 32),
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 24,
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
              if (results == null) return _buildEmptyState();
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
              return _buildResults(results);
            },
            loading: () => const CommonLoadingWidget(),
            error: (Object e, StackTrace? _) => CommonErrorWidget(error: e.toString()),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
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

  Widget _buildResults(SearchResultsDto results) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 100),
      children: [
        if (results.artists.isNotEmpty) ...[
          const CommonSectionTitle(title: 'Артисты'),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 32), // 32 + 8 (internal card padding) = 40
              itemCount: results.artists.length,
              itemBuilder: (context, i) => _buildArtistCard(results.artists[i]),
            ),
          ),
        ],
        if (results.albums.isNotEmpty) ...[
          const CommonSectionTitle(title: 'Альбомы'),
          SizedBox(
            height: 240,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 32), // 32 + 8 = 40
              itemCount: results.albums.length,
              itemBuilder: (context, i) => _buildAlbumCard(results.albums[i]),
            ),
          ),
        ],
        if (results.tracks.isNotEmpty) ...[
          const CommonSectionTitle(title: 'Треки'),
          ...results.tracks.map(_buildTrackTile),
          const SizedBox(height: 40),
        ],
      ],
    );
  }

  Widget _buildTrackTile(SimpleTrackDto track) {
    return CommonTrackTile(
      trackId: track.id,
      title: track.title,
      version: track.version,
      artists: track.artists,
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
          icon: Icon(Icons.play_arrow_rounded, color: Theme.of(context).colorScheme.primary),
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

  Widget _buildAlbumCard(SimpleAlbumDto album) {
    return CommonMediaCard(
      title: album.title,
      artists: album.artists,
      coverUrl: album.coverUrl,
      onTap: () => navigateTo(AppSection.album, album.id),
    );
  }

  Widget _buildArtistCard(SimpleArtistDto artist) {
    return CommonMediaCard(
      title: artist.name,
      coverUrl: artist.coverUrl,
      isCircle: true,
      size: 140,
      onTap: () => navigateTo(AppSection.artist, artist.id),
    );
  }
}
