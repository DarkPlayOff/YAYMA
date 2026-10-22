/// Central MD3-Expressive shape & spacing tokens for YAYMA's custom shell.
///
/// Use these instead of magic numbers so surfaces stay on one token system
/// (extra-large dialog corners, pill buttons, consistent 8dp-based spacing).
library;

import 'package:flutter/animation.dart';

abstract final class AppRadius {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 28;
  static const double xxxl = 32;
  static const double full = 1000;
}

abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
}

/// Motion of the cover art: it shrinks a little while the track is paused.
abstract final class AppCoverMotion {
  /// Small cover: the mini plate and the desktop player bar.
  static const double smallPausedScale = 0.96;

  /// Big cover: the home screen and the full screen player.
  static const double largePausedScale = 0.92;

  static const Duration duration = Duration(milliseconds: 350);
  static const Curve curve = Curves.easeInOutCubic;
}
