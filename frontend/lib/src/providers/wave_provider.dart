import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/api/playback.dart';

final FutureSignal<List<StationCategoryDto>> waveStationsSignal =
    futureSignal<List<StationCategoryDto>>(
      () async =>
          (await runRustFetch((ctx) => fetchWaveStations(ctx: ctx))) ?? [],
    );

class WaveController {
  static Future<void> playStation(String seed) async {
    await runRustAction((ctx) => startWave(ctx: ctx, seeds: [seed]));
    setSection(AppSection.home);
  }

  static Future<void> toggleStation(String seed) async {
    final currentSeeds = List<String>.from(currentWaveSeedsSignal());

    if (currentSeeds.contains(seed)) {
      currentSeeds.remove(seed);
    } else {
      // Remove 'user:onyourwave' if we're adding a specific seed
      currentSeeds.remove('user:onyourwave');

      // Group seeds by category (the part before the colon)
      final category = seed.split(':').first;

      // Special case: 'activity' and 'personal' are mutually exclusive as they
      // represent the main vibe type.
      if (category == 'activity' || category == 'personal') {
        currentSeeds.removeWhere(
          (s) => s.startsWith('activity:') || s.startsWith('personal:'),
        );
      } else {
        // For other categories (mood, local-language), remove existing ones
        // from the same category.
        currentSeeds.removeWhere((s) => s.startsWith('$category:'));
      }

      currentSeeds.add(seed);
    }

    // If no specific seeds are left, return to the default wave
    if (currentSeeds.isEmpty) {
      currentSeeds.add('user:onyourwave');
    }

    await runRustAction((ctx) => startWave(ctx: ctx, seeds: currentSeeds));
  }

  static Future<void> resetStations() async {
    final seeds = ['user:onyourwave'];
    await runRustAction((ctx) => startWave(ctx: ctx, seeds: seeds));
  }

  static Future<void> refresh() async {
    await waveStationsSignal.refresh();
  }
}
