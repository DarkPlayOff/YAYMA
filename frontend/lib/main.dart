import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:yayma/src/app/init.dart';
import 'package:yayma/src/ui/auth/auth_screens.dart';

Future<void> main() async {
  await AppInit.initialize();
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
          home: const RootScreen(),
        );
      },
    );
  }
}
