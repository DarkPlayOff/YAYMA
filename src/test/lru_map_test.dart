import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';

void main() {
  test('iterating values/entries/forEach while reading stays stable', () {
    final map = LruMap<String, int>(maximumSize: 4)
      ..['a'] = 1
      ..['b'] = 2;

    expect(map.values.toList(), [1, 2]);
    expect(map.entries.map((e) => e.key).toList(), ['a', 'b']);
    map.forEach((key, value) => map[key]);
  });
}
