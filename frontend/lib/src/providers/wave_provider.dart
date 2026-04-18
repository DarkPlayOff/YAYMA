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

    // In Yandex Music, each mood (e.g., personal:never-heard) is a 
    // standalone station.
    final wasSelected = currentSeeds.contains(seed);
    currentSeeds.clear();

    if (wasSelected) {
      // Button deselected - returning to the base wave
      currentSeeds.add('user:onyourwave');
    } else {
      // New mood selected
      currentSeeds.add(seed);
    }

    await runRustAction((ctx) => startWave(ctx: ctx, seeds: currentSeeds));
  }

  static Future<void> refresh() async {
    await waveStationsSignal.refresh();
  }
}
