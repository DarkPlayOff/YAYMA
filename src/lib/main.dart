import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

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
import 'package:yayma/src/features/core/services/app_logger.dart';
import 'package:yayma/src/features/core/services/global_hotkey_service.dart';
import 'package:yayma/src/features/core/theme/app_theme.dart';
import 'package:yayma/src/features/core/views/widgets/keyboard_focus.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Covers are cached on disk and decoded at display size, so a smaller cap
  // only costs a re-decode; the 100 MiB default is most of the app's RAM use.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;

  // Without these an exception during init or in a detached future only
  // reaches the console, leaving the user on a spinner with no explanation.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Uncaught Flutter error: ${details.exception}');
    // Short stack excerpt keeps the single log line readable.
    final stackExcerpt = details.stack
        ?.toString()
        .split('\n')
        .take(4)
        .join(' ');
    appLog(
      AppLogLevel.error,
      'Uncaught Flutter error: ${details.exception}'
      '${stackExcerpt == null ? '' : ' | stack: $stackExcerpt'}',
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught async error: $error\n$stack');
    appLog(AppLogLevel.error, 'Uncaught async error: $error');
    return true;
  };

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

  runApp(const MyApp());

  await appInitialization;

  var windowReady = false;
  if (isDesktop) {
    final window = WindowManager.instance.getCurrent();
    if (window != null) {
      final isCustom = customTitlebarSignal.value;

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

      window
        ..titleBarStyle = isCustom ? TitleBarStyle.hidden : TitleBarStyle.normal
        ..minimumSize = WindowPlacement.minimumSize.toNative()
        ..backgroundColor = const Color(0x00000000).toNative()
        ..isVisibleInTaskbar = true
        ..setSize(
          (savedBounds?.size ?? WindowPlacement.defaultSize).toNative(),
          false,
        );
      if (restoreBounds != null) {
        window.bounds = restoreBounds.toNative();
      } else {
        window.center();
      }
      if (savedMaximized) window.maximize();
      window
        ..show()
        ..focus();
      WindowPlacement.track();
      windowReady = true;
    }
  }

  // Defer optional desktop integrations until Flutter has rendered its first frame.
  await WidgetsBinding.instance.endOfFrame;

  if (windowReady) {
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
                child: Actions(
                  actions: unfocusOnTapOutside,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },
          home: const RootScreen(),
        );
      },
    );
  }
}
