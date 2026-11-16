import 'package:signals_flutter/signals_flutter.dart';

const double minVibeRenderScale = 0.25;
const double maxVibeRenderScale = 0.50;

/// Which background shader to show. Each value maps to
/// `assets/shaders/vibe_<name>.frag` and to a `vibe_style` setting in Rust.
enum VibeStyle {
  aurora('Сияние'),
  wave('Волна');

  const VibeStyle(this.label);

  final String label;

  static VibeStyle fromName(String? name) =>
      values.asNameMap()[name] ?? VibeStyle.aurora;
}

final FlutterSignal<bool> vibeVisibleSignal = signal(true);
final FlutterSignal<double> vibeRenderScaleSignal = signal(0.50);
final FlutterSignal<VibeStyle> vibeStyleSignal = signal(VibeStyle.aurora);
