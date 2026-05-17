import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/app/init.dart';
import 'package:yayma/src/providers/notification_provider.dart';
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
    final isCustom = simple.isCustomTitlebarEnabledSync();

    final windowOptions = WindowOptions(
      size: const Size(1280, 720),
      minimumSize: const Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: isCustom ? TitleBarStyle.hidden : TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return MaterialApp(
          title: 'YAYMA',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme:
                darkDynamic ??
                ColorScheme.fromSeed(
                  seedColor: Colors.deepOrange,
                  brightness: Brightness.dark,
                ),
            useMaterial3: true,
            fontFamily: 'Inter',
          ),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) {
            return GlobalNotificationListener(
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const RootScreen(),
        );
      },
    );
  }
}
