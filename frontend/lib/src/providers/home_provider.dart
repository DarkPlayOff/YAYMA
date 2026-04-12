import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/rust/api/playback.dart';

// Методы управления главной страницей
class HomeController {
  static Future<void> startMyWave() async {
    await runRustAction(
      (ctx) => startWave(ctx: ctx, seeds: ['user:onyourwave']),
    );
    setSection(AppSection.home);
  }
}
