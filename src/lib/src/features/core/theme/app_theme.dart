import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Material Orange 500 is the stable fallback before a cover palette is ready.
const Color defaultAccentColor = Color(0xFFFF9800);

/// The scheme used when no cover palette is available. Computed once: these
/// colours only change with the app's own constants.
final ColorScheme baseColorScheme = ColorScheme.fromSeed(
  seedColor: defaultAccentColor,
  brightness: Brightness.dark,
  dynamicSchemeVariant: DynamicSchemeVariant.expressive,
);

/// Merges a cover-derived scheme into the stable surface colours: the artwork
/// picks the accents, and the neutral base is re-seeded from the cover's own
/// primary so surfaces follow the track's hue too.
ColorScheme appColorScheme(ColorScheme? cover) {
  if (cover == null) return baseColorScheme;
  // The neutral base is seeded from the cover's own primary (not the fallback
  // orange), so surfaces carry the track's hue instead of one fixed warm tint.
  final base = ColorScheme.fromSeed(
    seedColor: cover.primary,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.expressive,
  );
  return cover.copyWith(
    surface: base.surface,
    surfaceContainerLowest: base.surfaceContainerLowest,
    surfaceContainerLow: base.surfaceContainerLow,
    surfaceContainer: base.surfaceContainer,
    surfaceContainerHigh: base.surfaceContainerHigh,
    surfaceContainerHighest: base.surfaceContainerHighest,
    surfaceBright: base.surfaceBright,
    surfaceDim: base.surfaceDim,
    onPrimaryContainer: base.onPrimaryContainer,
    onSecondaryContainer: base.onSecondaryContainer,
    onTertiaryContainer: base.onTertiaryContainer,
    onErrorContainer: base.onErrorContainer,
  );
}

/// Elevated translucent surface used by the player bar, the mini plate and
/// dialogs. Kept in one place so they all darken by the same amount.
Color surfaceOverlay(Color? surface) =>
    Color.lerp(surface, Colors.black, 0.4) ?? const Color(0xFF181818);

/// The six accent colours the wave shader consumes, in its expected order.
List<double> vibePalette(ColorScheme scheme) {
  List<double> c(Color col) => [
    (col.r * 255.0).round().clamp(0, 255) / 255.0,
    (col.g * 255.0).round().clamp(0, 255) / 255.0,
    (col.b * 255.0).round().clamp(0, 255) / 255.0,
  ];
  return [
    ...c(scheme.primary),
    ...c(scheme.secondary),
    ...c(scheme.tertiary),
    ...c(scheme.primaryContainer),
    ...c(scheme.secondaryContainer),
    ...c(scheme.tertiaryContainer),
  ];
}

final ThemeData defaultAppTheme = buildAppTheme(baseColorScheme);

ThemeData buildAppTheme(ColorScheme scheme) {
  final base = ThemeData.dark(useMaterial3: true);
  final textTheme = base.textTheme.copyWith(
    displayLarge: base.textTheme.displayLarge?.copyWith(
      fontWeight: FontWeight.w900,
      letterSpacing: -2.5,
      height: 1,
    ),
    displayMedium: base.textTheme.displayMedium?.copyWith(
      fontWeight: FontWeight.w900,
      letterSpacing: -2,
      height: 1.05,
    ),
    displaySmall: base.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -1,
    ),
    headlineLarge: base.textTheme.headlineLarge?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w700,
    ),
  );

  // Filled, elevated and outlined buttons share the same shape and metrics.
  final buttonStyle = FilledButton.styleFrom(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: Colors.black,
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    highlightColor: scheme.primary.withValues(alpha: 0.08),
    hoverColor: Colors.white.withValues(alpha: 0.04),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const FadeForwardsPageTransitionsBuilder(),
      },
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
      circularTrackColor: scheme.surfaceContainerHighest,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceOverlay(scheme.surfaceContainerHighest),
      surfaceTintColor: Colors.transparent,
      barrierColor: Platform.isAndroid ? Colors.transparent : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surfaceOverlay(scheme.surfaceContainerHighest),
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: Platform.isAndroid ? Colors.transparent : null,
      modalBackgroundColor: surfaceOverlay(scheme.surfaceContainerHighest),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      unselectedLabelStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w500,
      ),
      labelColor: scheme.onSurface,
      unselectedLabelColor: scheme.onSurfaceVariant,
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.28)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 13),
    ),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
}
