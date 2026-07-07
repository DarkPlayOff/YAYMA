import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/playback.dart';

class HomeController {
  static Future<void> startMyWave() async {
    final currentSeeds = currentWaveSeedsSignal();
    final seeds = currentSeeds.isNotEmpty ? currentSeeds : ['user:onyourwave'];

    await runRustAction(
      (ctx) => startWave(ctx: ctx, seeds: seeds),
    );
    setSection(AppSection.home);
  }
}
