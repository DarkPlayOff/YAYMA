import 'package:signals_flutter/signals_flutter.dart';

const double minVibeRenderScale = 0.25;
const double maxVibeRenderScale = 0.50;

final FlutterSignal<bool> vibeVisibleSignal = signal(true);
final FlutterSignal<double> vibeRenderScaleSignal = signal(0.50);
final FlutterSignal<bool> blurEffectsEnabledSignal = signal(true);
