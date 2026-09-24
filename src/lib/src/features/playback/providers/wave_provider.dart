import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart' as rust_playback;

final FutureSignal<List<StationCategoryDto>> waveStationsSignal =
    futureSignal<List<StationCategoryDto>>(
      () async =>
          (await runRustFetch((ctx) => fetchWaveStations(ctx: ctx))) ?? [],
    );

class WaveController {
  static Future<void> playStation(String seed) async {
    await runRustAction(
      (ctx) => rust_playback.startWave(ctx: ctx, seeds: [seed]),
    );
    setSection(AppSection.home);
  }

  /// Toggle is fully owned by Rust (`toggle_wave_station`): no seed
  /// splitting/filtering in Dart.
  static Future<void> toggleStation(String seed) async {
    await runRustAction(
      (ctx) => rust_playback.toggleWaveStation(ctx: ctx, seed: seed),
    );
  }

  /// "My wave": keeps current seeds, falls back to `user:onyourwave`
  /// when empty. Fully owned by Rust ([startMyWave]).
  static Future<void> startMyWave() async {
    await runRustAction((ctx) => rust_playback.startMyWave(ctx: ctx));
    setSection(AppSection.home);
  }

  /// Reset to the default wave with a single Rust call.
  /// No manual seed manipulation in Dart.
  static Future<void> resetStations() async {
    await runRustAction(
      (ctx) => rust_playback.startWave(ctx: ctx, seeds: ['user:onyourwave']),
    );
  }

  static Future<void> refresh() async {
    await waveStationsSignal.refresh();
  }
}
