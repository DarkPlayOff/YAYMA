import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/theme/app_theme.dart';
import 'package:yayma/src/features/core/utils/lru_map.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/simple.dart' as rust;

// Keep only the covers around the current queue position. Apart from avoiding
// repeated palette extraction when going back, this lets the normal next-track
// transition do its image work before the track actually changes.
//
// This second level next to Flutter's ImageCache is intentional: ImageCache
// stores decoded images, not the derived ColorScheme palettes, and
// ColorScheme.fromImageProvider is the expensive part worth memoizing.
// In-flight extractions are deduplicated by caching the Future itself, so
// concurrent readers share one palette computation (see [LruMap]).
const int _preparedCoverCacheLimit = 6;
final LruMap<String, Future<ColorScheme?>> _preparedCoverSchemes = LruMap(
  maximumSize: _preparedCoverCacheLimit,
);

final LruMap<String, Future<List<Color>>> _coverTintCache = LruMap(
  maximumSize: 6,
);

// Intentionally the cheap 24px hue histogram, not the Celebi seed: the context
// sheet should not wait for the isolate quantizer.
/// Up to three accent colours of a cover, picked from its most frequent hues.
///
/// Reads the already-cached file, so no extra network. Returns an empty list
/// when the cover is missing or nearly greyscale. [pixels] should be the size
/// the cover is drawn at, so the same cached preset is reused.
Future<List<Color>> coverTint({
  String? coverUrl,
  Uri? localUri,
  int pixels = 300,
}) {
  final url = coverUrl ?? localUri?.toString();
  if (url == null) return Future.value(const []);
  final requestUrl = localUri != null && localUri.scheme == 'file'
      ? url
      : resolveCoverUrl(url, pixels);
  final cached = _coverTintCache[requestUrl];
  if (cached != null) return cached;

  final future = _loadCoverTint(requestUrl, localUri);
  _coverTintCache[requestUrl] = future;
  // Don't keep misses around, matching the previous behaviour of only caching
  // successfully read covers.
  unawaited(
    future.then((colors) {
      if (colors.isEmpty &&
          identical(_coverTintCache.peek(requestUrl), future)) {
        final _ = _coverTintCache.remove(requestUrl);
      }
    }),
  );
  return future;
}

Future<List<Color>> _loadCoverTint(String requestUrl, Uri? localUri) async {
  try {
    final String? path;
    if (localUri != null && localUri.scheme == 'file') {
      path = localUri.toFilePath();
    } else {
      final ctx = appContextSignal.value;
      if (ctx == null) return const [];
      path = await rust.getCachedImagePath(ctx: ctx, url: requestUrl);
    }
    if (path == null) return const [];
    return await _colorsOfFile(path);
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

// At most two extractions run at once. Without the cap, skipping N tracks
// leaves N stale isolate jobs competing with the palette of the track the
// user actually stopped on.
const int _coverExtractionSlots = 2;
int _coverExtractionsActive = 0;
final List<({String url, Completer<ColorScheme?> completer})>
_coverExtractionQueue = [];

Future<ColorScheme?> _queueCoverExtraction(String url) {
  final completer = Completer<ColorScheme?>();
  _coverExtractionQueue.add((url: url, completer: completer));
  _drainCoverExtractions();
  return completer.future;
}

void _drainCoverExtractions() {
  if (_coverExtractionsActive >= _coverExtractionSlots) return;

  final current = currentCoverUrlSignal.peek();
  final relevant = {
    current,
    previousTrackSignal.peek()?.coverUrl,
    nextTrackSignal.peek()?.coverUrl,
  };

  // Drop work for tracks the user already skipped past; resolve it as a miss
  // so the cache does not keep the entry.
  for (final entry in _coverExtractionQueue) {
    if (!relevant.contains(entry.url)) entry.completer.complete(null);
  }
  _coverExtractionQueue.removeWhere((entry) => !relevant.contains(entry.url));

  while (_coverExtractionsActive < _coverExtractionSlots &&
      _coverExtractionQueue.isNotEmpty) {
    // The landed track wins over the neighbour prefetches.
    final currentIndex = _coverExtractionQueue.indexWhere(
      (entry) => entry.url == current,
    );
    final entry = _coverExtractionQueue.removeAt(
      currentIndex < 0 ? 0 : currentIndex,
    );

    _coverExtractionsActive++;
    unawaited(
      _extractCoverScheme(entry.url)
          .then((scheme) {
            if (!entry.completer.isCompleted) entry.completer.complete(scheme);
          })
          .whenComplete(() {
            _coverExtractionsActive--;
            _drainCoverExtractions();
          }),
    );
  }
}

Future<ColorScheme?> _prepareCoverScheme(String url) {
  final cached = _preparedCoverSchemes[url];
  if (cached != null) return cached;

  final future = _queueCoverExtraction(url);
  _preparedCoverSchemes[url] = future;
  // Don't poison the cache with misses or errors: null results and failures
  // are evicted so the next request retries instead of reusing the failure.
  // The identity check guards against evicting a fresher entry inserted
  // for the same url.
  unawaited(
    future.then<ColorScheme?>((scheme) => scheme, onError: (_) => null).then((
      scheme,
    ) {
      if (scheme == null &&
          identical(_preparedCoverSchemes.peek(url), future)) {
        final _ = _preparedCoverSchemes.remove(url);
      }
    }),
  );
  return future;
}

// Quantizing a 32x32 cover with 128 clusters takes hundreds of milliseconds
// and used to run on the UI isolate, stalling every skipped track. Only the
// cheap 32px decode stays here; the same quantization pipeline as
// `ColorScheme.fromImageProvider` runs on a worker isolate, since the engine's
// image decoder is not available there.
Future<int?> _coverSeed(String path) async {
  try {
    final codec = await ui.instantiateImageCodec(
      await File(path).readAsBytes(),
      targetWidth: 32,
      targetHeight: 32,
    );
    final Uint32List pixels;
    try {
      final frame = await codec.getNextFrame();
      final bytes = await frame.image.toByteData();
      frame.image.dispose();
      if (bytes == null) return null;
      pixels = bytes.buffer.asUint32List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 4,
      );
    } finally {
      codec.dispose();
    }

    return await Isolate.run(() {
      return QuantizerCelebi()
          .quantize(pixels, 128, returnInputPixelToClusterPixel: true)
          .then((quantized) {
            // toByteData() is RGBA, so the uint32 view is ABGR; Score wants ARGB.
            final colorToCount = quantized.colorToCount.map(
              (abgr, count) => MapEntry(_argbFromAbgr(abgr), count),
            );
            final scored = Score.score(colorToCount, desired: 1);
            return scored.isEmpty ? null : scored.first;
          });
    });
  } on Object catch (error) {
    debugPrint('Cover seed extraction failed: $error');
    return null;
  }
}

int _argbFromAbgr(int abgr) {
  const exceptRMask = 0xFF00FFFF;
  const onlyRMask = ~exceptRMask;
  const exceptBMask = 0xFFFFFF00;
  const onlyBMask = ~exceptBMask;
  final r = (abgr & onlyRMask) >> 16;
  final b = abgr & onlyBMask;
  return (abgr & exceptRMask & exceptBMask) | (b << 16) | r;
}

Future<ColorScheme?> _extractCoverScheme(String url) async {
  try {
    final ctx = appContextSignal.value;
    if (ctx == null) return null;

    final path = await rust.getCachedImagePath(ctx: ctx, url: url);
    if (path == null) return null;

    final file = File(path);
    final seed = await _coverSeed(path);
    if (seed == null) return null;

    // Default variant (tonalSpot), like the pre-refactor
    // `ColorScheme.fromImageProvider` call: it keeps the cover's hue, while
    // expressive rotates the primary palette 240° away from the source color.
    final scheme = M3EColorScheme.dark(seedColor: Color(seed));

    // Warm the exact decoded size used by BlurredCoverBackground. Resolving
    // an ImageProvider is enough to put it into Flutter's shared image cache.
    final backgroundProvider = ResizeImage(
      FileImage(file),
      width: 60,
      height: 60,
    );
    final stream = backgroundProvider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) => stream.removeListener(listener),
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);

    return scheme;
  } on Object catch (error) {
    debugPrint('Cover preparation failed: $error');
    return null;
  }
}

// Effect to update the scheme, normally from the already prepared queue entry.
final EffectCleanup _persistentColorSchemeEffect = effect(() {
  final url = currentCoverUrlSignal();

  if (url == null || appContextSignal.value == null) {
    colorSchemeSignal.value = null;
    appThemeSignal.value = null;
    return;
  }

  unawaited(() async {
    final scheme = await _prepareCoverScheme(url);
    if (scheme == null) return;

    // Check if the track hasn't changed while preparation was in flight.
    if (currentCoverUrlSignal() != url) return;

    // Let the track-change frame (artwork, metadata, lyrics) go out first and
    // paint the recolour on the next one.
    await SchedulerBinding.instance.endOfFrame;
    if (currentCoverUrlSignal() != url) return;

    colorSchemeSignal.value = scheme;
    appThemeSignal.value = buildAppTheme(appColorScheme(scheme));
  }());
});

// Queue updates happen well ahead of playback. Prepare both neighbours so
// next/previous buttons and automatic advancement don't decode on transition.
final EffectCleanup _adjacentCoverPrecacheEffect = effect(() {
  final previousUrl = previousTrackSignal()?.coverUrl;
  final nextUrl = nextTrackSignal()?.coverUrl;
  if (previousUrl != null) unawaited(_prepareCoverScheme(previousUrl));
  if (nextUrl != null && nextUrl != previousUrl) {
    unawaited(_prepareCoverScheme(nextUrl));
  }
});

/// Reading the effects starts them; the palette itself is pulled lazily.
final List<EffectCleanup> _coverThemeEffects = [
  _persistentColorSchemeEffect,
  _adjacentCoverPrecacheEffect,
];

void activateCoverTheme() => _coverThemeEffects;

/// Drops the memoized palettes between sessions.
void clearCoverPalettes() {
  _preparedCoverSchemes.clear();
  _coverTintCache.clear();
}
