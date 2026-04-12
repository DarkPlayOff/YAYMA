import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';

// Сигнал поискового запроса
final FlutterSignal<String> searchQuerySignal = signal<String>('');

// Сигнал результатов поиска (автоматически обновляется при изменении запроса с задержкой)
final FutureSignal<SearchResultsDto?>
searchResultsSignal = futureSignal<SearchResultsDto?>(() async {
  final query = searchQuerySignal.value;
  if (query.trim().isEmpty) return null;

  final ctx = appContextSignal.value;
  if (ctx == null) return null;

  // Добавляем искусственную задержку (debounce)
  await Future<void>.delayed(const Duration(milliseconds: 500));

  // Если за это время запрос изменился, этот фьючер будет отменен автоматически сигналами
  return search(ctx: ctx, query: query);
});

void setSearchQuery(String query) {
  searchQuerySignal.value = query;
}
