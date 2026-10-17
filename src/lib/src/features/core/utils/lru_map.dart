import 'dart:collection';

/// Minimal least-recently-used map backed by a [LinkedHashMap].
///
/// Reading via `[]` or writing via `[]=` promotes the entry to the
/// most-recently-used position; inserting past [maximumSize] evicts the
/// least-recently-used entry. Iteration ([keys], [values], [entries],
/// [forEach]) does not affect recency.
///
/// Replaces the copy-pasted remove/reinsert/evict blocks previously spread
/// across providers. package:collection 1.19.1 ships no LRU map and
/// package:async's AsyncCache is a single-slot TTL cache, so neither is
/// a substitute for a bounded multi-key cache — hence this small helper
/// instead of a new third-party dependency.
final class LruMap<K, V> with MapMixin<K, V> {
  LruMap({required this.maximumSize, this.onEvict})
    : assert(maximumSize > 0, 'maximumSize must be positive');

  final int maximumSize;

  /// Called for every entry dropped by eviction (the `[]=` overflow path),
  /// [remove] and [clear]. Not called when `[]=` merely replaces an entry's
  /// value — replacement is the caller's lifetime to manage.
  final void Function(K key, V value)? onEvict;

  final LinkedHashMap<K, V> _entries = LinkedHashMap();

  @override
  V? operator [](Object? key) {
    if (!_entries.containsKey(key)) return null;
    // Remove + reinsert moves the entry to the MRU position.
    final value = _entries.remove(key);
    _entries[key! as K] = value as V;
    return value;
  }

  @override
  void operator []=(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maximumSize) {
      final evictedKey = _entries.keys.first;
      final evicted = _entries.remove(evictedKey);
      if (evicted != null) onEvict?.call(evictedKey, evicted);
    }
  }

  /// Returns the value without affecting recency (unlike `[]`).
  V? peek(K key) => _entries[key];

  @override
  V? remove(Object? key) {
    final value = _entries.remove(key);
    if (value != null) onEvict?.call(key as K, value);
    return value;
  }

  @override
  Iterable<K> get keys => _entries.keys;

  @override
  void clear() {
    if (onEvict == null) {
      _entries.clear();
      return;
    }
    final dropped = List.of(_entries.entries);
    _entries.clear();
    for (final entry in dropped) {
      onEvict!.call(entry.key, entry.value);
    }
  }
}
