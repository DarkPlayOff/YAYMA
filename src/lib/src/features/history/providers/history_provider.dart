import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart';

/// Listening history. Re-fetched on every track change, so a track that just
/// started shows up at the top without a manual refresh.
final FutureSignal<List<SimpleTrackDto>> historyTracksSignal =
    futureSignal<List<SimpleTrackDto>>(() async {
      currentTrackIdSignal.value;

      final ctx = appContextSignal.value;
      if (ctx == null) return const [];

      return await getHistory(ctx: ctx);
    });
