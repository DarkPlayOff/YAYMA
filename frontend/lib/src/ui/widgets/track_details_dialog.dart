import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/ui/widgets/common_ui.dart';

class TrackDetailsDialog extends StatelessWidget {
  final String trackId;

  const TrackDetailsDialog({required this.trackId, super.key});

  static void show(BuildContext context, String trackId) {
    unawaited(showDialog<void>(
      context: context,
      builder: (context) => TrackDetailsDialog(trackId: trackId),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final detailsAsync = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return rust.getTrackDetails(ctx: ctx, trackId: trackId);
    });

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      surfaceTintColor: Colors.transparent,
      title: const Text(
        'О треке',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 500,
        child: Watch((context) {
          final result = detailsAsync.value;
          return result.map(
            data: (details) {
              if (details == null) {
                return const Center(child: Text('Загрузка...'));
              }
              return _buildDetails(details);
            },
            loading: () => const CommonLoadingWidget(),
            error: (Object e, _) => CommonErrorWidget(error: e.toString()),
          );
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Закрыть', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
        ),
      ],
    );
  }

  bool _isValid(String? value) {
    if (value == null || value.isEmpty || value.trim() == '-') return false;
    return true;
  }

  Widget _buildDetails(TrackDetailsDto details) {
    final music = details.musicAuthors.where((a) => a != '-').toList();
    final lyrics = details.lyricsAuthors.where((a) => a != '-').toList();
    final platforms = details.sourcePlatforms.where((a) => a != '-').toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isValid(details.title)) _buildInfoRow('Название', details.title),
        _buildInfoRow(
          'Исполнитель',
          details.artists.map((a) => a.name).join(', '),
        ),
        if (_isValid(details.album)) _buildInfoRow('Альбом', details.album!),
        if (_isValid(details.label)) _buildInfoRow('Лейбл', details.label!),
        if (music.isNotEmpty) _buildInfoRow('Автор музыки', music.join(', ')),
        if (lyrics.isNotEmpty) _buildInfoRow('Автор текста', lyrics.join(', ')),
        if (platforms.isNotEmpty)
          _buildInfoRow('Источник фонограммы', platforms.join(', ')),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
