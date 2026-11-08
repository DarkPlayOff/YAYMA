import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart';

/// Page size for the history list, matching the liked-tracks batching.
const int historyPageSize = 50;

/// Listening history as recorded by the server (the `/plays` reports), so it
/// covers plays from every device. Loaded 50 entries at a time; the endpoint
/// has no paging, so each page re-reads its id window and fetches only its own
/// track models.
final FlutterSignal<List<SimpleTrackDto>> historyTracksSignal =
    signal<List<SimpleTrackDto>>([]);
final FlutterSignal<bool> isHistoryLoadingSignal = signal<bool>(false);
final FlutterSignal<bool> historyHasMoreSignal = signal<bool>(true);

/// Reloads the history from the first page.
Future<void> refreshHistory() async {
  if (isHistoryLoadingSignal.value) return;
  historyTracksSignal.value = const [];
  historyHasMoreSignal.value = true;
  await _loadHistoryPage();
}

/// Appends the next page; no-op while a page is in flight or at the end.
Future<void> loadMoreHistory() async {
  if (isHistoryLoadingSignal.value || !historyHasMoreSignal.value) return;
  await _loadHistoryPage();
}

Future<void> _loadHistoryPage() async {
  isHistoryLoadingSignal.value = true;
  try {
    final offset = historyTracksSignal.value.length;
    final page = await runRustFetch(
      (ctx) => getHistory(
        ctx: ctx,
        offset: BigInt.from(offset),
        limit: BigInt.from(historyPageSize),
      ),
    );
    if (page == null) {
      // Stop paging on failure instead of retrying on every scroll tick;
      // pull-to-refresh starts over.
      historyHasMoreSignal.value = false;
      return;
    }
    historyTracksSignal.value = [...historyTracksSignal.value, ...page];
    if (page.length < historyPageSize) historyHasMoreSignal.value = false;
  } finally {
    isHistoryLoadingSignal.value = false;
  }
}
