import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// The single width ladder for layout switches. Widgets pick the nearest one
/// instead of hardcoding their own number.
///
/// [compactBreakpoint] is the shell switch (below it the touch layout is used).
/// The desktop window minimum (800x600) sits above it, so desktop never goes
/// compact.
const double compactBreakpoint = 600;
const double mediumBreakpoint = 900;
const double wideBreakpoint = 1100;

extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  /// Android always uses the touch layout, including tablets: a large Android
  /// screen must not fall back to the desktop navbar and 40dp page edges.
  bool get isNarrow => Platform.isAndroid || screenWidth < compactBreakpoint;
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  double get horizontalPadding => isNarrow ? 20.0 : 40.0;
  double get topPadding => isNarrow ? 40.0 : 60.0;

  EdgeInsets get viewPadding =>
      EdgeInsets.fromLTRB(horizontalPadding, topPadding, horizontalPadding, 20);
}
