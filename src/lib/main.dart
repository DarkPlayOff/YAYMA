import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/app/init.dart';
import 'package:yayma/src/app/system_tray.dart';
import 'package:yayma/src/app/window_placement.dart';
import 'package:yayma/src/features/auth/views/auth/auth_screens.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/services/global_hotkey_service.dart';
import 'package:yayma/src/features/core/theme/app_theme.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  if (!isDesktop) {
    // Draw behind the Android system bars so the blurred cover background
    // shows through the navigation area instead of an opaque black strip.
    // The floating navbar itself is lifted above the buttons via viewPadding.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );
  }
  final appInitialization = AppInit.initialize();
  final windowInitialization = isDesktop
      ? windowManager.ensureInitialized()
      : Future<void>.value();

  runApp(const MyApp());

  await Future.wait([appInitialization, windowInitialization]);

  Future<void>? windowReady;
  if (isDesktop) {
    final isCustom = customTitlebarSignal.value;
    customTitlebarSignal.value = isCustom;

    final savedBounds = await WindowPlacement.loadBounds();
    final savedMaximized = await WindowPlacement.loadMaximized();
    // On Wayland the compositor owns positioning; on other platforms the
    // saved monitor may be gone — in both cases restore size and center.
    final restoreBounds =
        savedBounds != null &&
            !WindowPlacement.isWayland &&
            await WindowPlacement.isPositionVisible(savedBounds)
        ? savedBounds
        : null;

    final windowOptions = WindowOptions(
      size: savedBounds?.size ?? WindowPlacement.defaultSize,
      minimumSize: WindowPlacement.minimumSize,
      center: restoreBounds == null,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: isCustom ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    windowReady = windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (restoreBounds != null) {
        await windowManager.setBounds(restoreBounds);
      }
      if (savedMaximized) {
        await windowManager.maximize();
      }
      await windowManager.show();
      await windowManager.focus();
      WindowPlacement.track();
    });
  }

  // Defer optional desktop integrations until Flutter has rendered its first frame.
  await WidgetsBinding.instance.endOfFrame;

  if (windowReady != null) {
    await windowReady;
    await SystemTrayManager.instance.initialize();
    await GlobalHotkeyService.initialize();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        // The whole ThemeData arrives prebuilt from the cover-palette path,
        // so a track change does no colour math in this build.
        final theme = appThemeSignal() ?? defaultAppTheme;

        return MaterialApp(
          title: 'YAYMA',
          debugShowCheckedModeBanner: false,
          theme: theme,
          // Palette changes on every track change; animating the swap
          // rebuilds the whole tree for every frame of the lerp.
          themeAnimationDuration: Duration.zero,
          themeAnimationCurve: Curves.easeOut,
          builder: (context, child) {
            return RepaintBoundary(
              child: GlobalNotificationListener(
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
          home: const RootScreen(),
        );
      },
    );
  }
}
