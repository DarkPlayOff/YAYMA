import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/rust/api/simple.dart';

final LruMap<String, List<Color>> _tintCache = LruMap(maximumSize: 200);

/// Up to three accent colours of a cover, picked from its most frequent hues.
///
/// Reads the already-cached file, so no extra network. Returns an empty list
/// when the cover is missing or nearly greyscale. [pixels] should be the size
/// the cover is drawn at, so the same cached preset is reused.
Future<List<Color>> coverTint({
  String? coverUrl,
  Uri? localUri,
  int pixels = 300,
}) async {
  final url = coverUrl ?? localUri?.toString();
  if (url == null) return const [];
  final requestUrl = localUri != null && localUri.scheme == 'file'
      ? url
      : resolveCoverUrl(url, pixels);
  final cached = _tintCache[requestUrl];
  if (cached != null) return cached;

  try {
    final String? path;
    if (localUri != null && localUri.scheme == 'file') {
      path = localUri.toFilePath();
    } else {
      final ctx = appContextSignal.value;
      if (ctx == null) return const [];
      path = await getCachedImagePath(ctx: ctx, url: requestUrl);
    }
    if (path == null) return const [];

    final colors = await _colorsOfFile(path);
    _tintCache[requestUrl] = colors;
    return colors;
  } on Object {
    return const [];
  }
}

Future<List<Color>> _colorsOfFile(String path) async {
  final codec = await ui.instantiateImageCodec(
    await File(path).readAsBytes(),
    targetWidth: 24,
    targetHeight: 24,
  );
  try {
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData();
    frame.image.dispose();
    if (data == null) return const [];

    final bytes = data.buffer.asUint8List();
    final counts = <int, int>{};
    final sums = <int, List<int>>{};
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i + 3] < 200) continue;
      final r = bytes[i];
      final g = bytes[i + 1];
      final b = bytes[i + 2];
      final hsv = HSVColor.fromColor(Color.fromARGB(255, r, g, b));
      // Near-greys would only desaturate the result.
      if (hsv.saturation < 0.25) continue;
      final bucket = (hsv.hue / 30).floor();
      counts[bucket] = (counts[bucket] ?? 0) + 1;
      final sum = sums.putIfAbsent(bucket, () => [0, 0, 0]);
      sum[0] += r;
      sum[1] += g;
      sum[2] += b;
    }
    if (counts.isEmpty) return const [];

    final top = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return [
      for (final bucket in top.take(3))
        HSVColor.fromColor(
          Color.fromARGB(
            255,
            sums[bucket]![0] ~/ counts[bucket]!,
            sums[bucket]![1] ~/ counts[bucket]!,
            sums[bucket]![2] ~/ counts[bucket]!,
          ),
        ).withSaturation(0.72).withValue(0.62).toColor(),
    ];
  } finally {
    codec.dispose();
  }
}
