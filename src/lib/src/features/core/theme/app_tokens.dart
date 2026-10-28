/// Central MD3-Expressive shape & spacing tokens for YAYMA's custom shell.
///
/// Use these instead of magic numbers so surfaces stay on one token system
/// (extra-large dialog corners, pill buttons, consistent 8dp-based spacing).
library;

import 'package:flutter/animation.dart';

/// Corner radii for every rounded surface in the app.
///
/// The scale steps up with the size of the surface it wraps: small artwork and
/// inline chips take [xs] and [sm], cards take [md], page-level panels take
/// [lg] and above, and anything circular takes [full]. A value that is not on
/// this scale is a bug unless the widget is drawn from outside the app.
abstract final class AppRadius {
  /// Tiny artwork and inline chips: settings row thumbnails, add-to-playlist
  /// tiles, the cover inside the mini player.
  static const double xs = 8;

  /// Small controls and list tiles: track tile hover surface, cover in the
  /// player bar, context menu items, compact text fields.
  static const double sm = 12;

  /// Cards: media cards, covers on the home screen, playlist cards, bordered
  /// settings cards.
  static const double md = 16;

  /// Large fields and section surfaces: the playlist search field, the
  /// navigation bar section surface.
  static const double lg = 20;

  /// Page-level panels: the desktop player bar, the inner panel of the full
  /// screen player.
  static const double xl = 24;

  /// Floating navigation surfaces and menus.
  static const double xxl = 28;

  /// Pills and sheets: the navigation pill, the mini player, the top of the
  /// full screen player panel.
  static const double xxxl = 32;

  /// Circles: round buttons, avatars, anything that must read as a capsule
  /// instead of a rounded rectangle.
  static const double full = 1000;
}

/// Spacing between and inside surfaces, on a 4dp grid.
///
/// Reach for the largest step that still fits: [lg] and [xxl] for the gaps
/// between sections, [md] for padding inside a card, [xs] and [xxs] for gaps
/// between an icon and its label. Page edges use 20 on narrow screens and 40
/// on wide ones, matching `horizontalPadding` in `responsive.dart`.
abstract final class AppSpacing {
  /// Tightest gap: between an icon and its label, between stacked lines.
  static const double xxs = 4;

  /// Row gaps, space between a cover and its text block.
  static const double xs = 8;

  /// Padding inside compact rows and chips.
  static const double sm = 12;

  /// Padding inside cards and dialogs, gap between related controls.
  static const double md = 16;

  /// Padding inside page panels, gap between blocks of a section.
  static const double lg = 20;

  /// Gap between sections of one screen.
  static const double xl = 24;

  /// Gap before a major section, top padding on a narrow screen.
  static const double xxl = 32;

  /// Page edges on a wide screen, top padding of a detail page.
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
