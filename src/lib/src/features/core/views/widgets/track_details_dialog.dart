import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';

class TrackDetailsDialog extends SignalWidget {
  final String trackId;

  const TrackDetailsDialog({required this.trackId, super.key});

  static void show(BuildContext context, String trackId) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => TrackDetailsDialog(trackId: trackId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detailsAsync = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return rust.getTrackDetails(ctx: ctx, trackId: trackId);
    });

    return SignalBuilder(
      builder: (context) {
        final result = detailsAsync.value;
        return result.map(
          loading: () => const Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: SizedBox(
              width: 72,
              height: 72,
              child: CommonLoadingWidget(),
            ),
          ),
          data: (details) => _buildDialog(
            context,
            details == null
                ? const Center(child: Text('Загрузка...'))
                : _buildDetails(context, details),
          ),
          error: (Object e, _) => _buildDialog(
            context,
            CommonErrorWidget(error: e.toString()),
          ),
        );
      },
    );
  }

  Widget _buildDialog(BuildContext context, Widget content) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        'О треке',
        style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.bold),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: content,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Закрыть',
            style: TextStyle(color: cs.primary),
          ),
        ),
      ],
    );
  }

  bool _isValid(String? value) {
    if (value == null || value.isEmpty || value.trim() == '-') return false;
    return true;
  }

  Widget _buildDetails(BuildContext context, TrackDetailsDto details) {
    final music = details.musicAuthors.where((a) => a != '-').toList();
    final lyrics = details.lyricsAuthors.where((a) => a != '-').toList();
    final platforms = details.sourcePlatforms.where((a) => a != '-').toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isValid(details.title))
          _buildInfoRow(context, 'Название', details.title),
        _buildInfoRow(
          context,
          'Исполнитель',
          details.artists.map((a) => a.name).join(', '),
        ),
        if (_isValid(details.album))
          _buildInfoRow(context, 'Альбом', details.album!),
        if (_isValid(details.label))
          _buildInfoRow(context, 'Лейбл', details.label!),
        if (music.isNotEmpty)
          _buildInfoRow(context, 'Автор музыки', music.join(', ')),
        if (lyrics.isNotEmpty)
          _buildInfoRow(context, 'Автор текста', lyrics.join(', ')),
        if (platforms.isNotEmpty)
          _buildInfoRow(
            context,
            'Источник фонограммы',
            platforms.join(', '),
          ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: cs.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(color: cs.onSurface, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
