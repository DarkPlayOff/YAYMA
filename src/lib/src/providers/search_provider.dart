import 'dart:async';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';

final FlutterSignal<String> searchQuerySignal = signal<String>('');

/// Search results signal (automatically updates when searchQuerySignal changes)
final FutureSignal<SearchResultsDto?> searchResultsSignal =
    futureSignal<SearchResultsDto?>(() async {
      final query = searchQuerySignal.value;
      if (query.trim().isEmpty) return null;

      final ctx = appContextSignal.value;
      if (ctx == null) return null;

      return search(ctx: ctx, query: query);
    });

Timer? _searchDebounce;

void setSearchQuery(String query) {
  _searchDebounce?.cancel();
  _searchDebounce = Timer(const Duration(milliseconds: 300), () {
    searchQuerySignal.value = query;
  });
}

