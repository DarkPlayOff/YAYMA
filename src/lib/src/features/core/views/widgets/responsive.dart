import 'dart:io';

import 'package:flutter/material.dart';

extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;

  bool get isNarrow => screenWidth < 600;
  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  double get horizontalPadding => isNarrow ? 20.0 : 40.0;
  double get topPadding => isNarrow ? 40.0 : 60.0;

  EdgeInsets get viewPadding => EdgeInsets.fromLTRB(
    horizontalPadding,
    topPadding,
    horizontalPadding,
    20,
  );
}
