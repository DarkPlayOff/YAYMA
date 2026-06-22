import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';

final FlutterSignal<String> searchQuerySignal = signal<String>('');

/// Search results signal (automatically updates with debounce)
final FutureSignal<SearchResultsDto?>
searchResultsSignal = futureSignal<SearchResultsDto?>(() async {
  final query = searchQuerySignal.value;
  if (query.trim().isEmpty) return null;

  final ctx = appContextSignal.value;
  if (ctx == null) return null;

  // Artificial delay (debounce)
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // If the query changes during this time, this future is automatically cancelled
  return search(ctx: ctx, query: query);
});

void setSearchQuery(String query) {
  searchQuerySignal.value = query;
}
