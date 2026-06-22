import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/app/init.dart';
import 'package:yayma/src/app/system_tray.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/simple.dart' as simple;
import 'package:yayma/src/ui/auth/auth_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Future.wait([
    AppInit.initialize(),
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      windowManager.ensureInitialized(),
  ]);

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final isCustom = await simple.isCustomTitlebarEnabledInit();
    customTitlebarSignal.value = isCustom;

    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      minimumSize: const Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: isCustom ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await SystemTrayManager.instance.initialize();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final trackScheme = colorSchemeSignal().value;
        final currentScheme =
            trackScheme ??
            ColorScheme.fromSeed(
              seedColor: Colors.deepOrange,
              brightness: Brightness.dark,
            );

        return MaterialApp(
          title: 'YAYMA',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: currentScheme,
            useMaterial3: true,
            fontFamily: 'Inter',
            scaffoldBackgroundColor: Colors.black,
          ),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) {
            return AnimatedTheme(
              data: ThemeData(
                colorScheme: currentScheme,
                useMaterial3: true,
                fontFamily: 'Inter',
                scaffoldBackgroundColor: Colors.black,
              ),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: RepaintBoundary(
                child: GlobalNotificationListener(
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
