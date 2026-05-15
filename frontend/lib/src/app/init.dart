import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart'
    show accountSignal, appContextSignal, authSignal;
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/auth.dart';
import 'package:yayma/src/rust/api/simple.dart' as simple;
import 'package:yayma/src/rust/app/context.dart';
import 'package:yayma/src/rust/frb_generated.dart';

// Export for backward compatibility
export 'package:yayma/src/providers/auth_provider.dart'
    show initAuth, login, logout;

/// Centralized application initialization module
class AppInit {
  static Future<void> initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    SignalsObserver.instance = null;
    await RustLib.init();

    final appDir = await getApplicationDocumentsDirectory();
    await simple.initAppInfrastructure(basePath: appDir.path);

    unawaited(_initializeAuthAndServices());
  }

  static Future<void> _initializeAuthAndServices() async {
    final context = await tryAutoLogin();
    appContextSignal.value = context;

    if (context == null) {
      authSignal.value = const AsyncData(false);
      return;
    }

    // Parallel initialization of dependent services
    await Future.wait([
      _loadAccountInfo(context),
      initLibrary(),
      initPlayback(),
    ]);

    authSignal.value = const AsyncData(true);
  }

  static Future<void> _loadAccountInfo(AppContext context) async {
    try {
      final account = await getAccountInfo(ctx: context);
      accountSignal.value = account;
    } on Exception {
      accountSignal.value = null;
    }
  }

  static Future<void> login(String token) async {
    authSignal.value = const AsyncLoading();
    try {
      final context = await loginWithToken(token: token);
      appContextSignal.value = context;

      await Future.wait([
        _loadAccountInfo(context),
        initLibrary(),
        initPlayback(),
      ]);

      authSignal.value = const AsyncData(true);
    } on Object catch (e, st) {
      authSignal.value = AsyncError(e, st);
    }
  }

  static Future<void> logout() async {
    await PlaybackController.stop();
    await clearToken();
    accountSignal.value = null;
    appContextSignal.value = null;
    authSignal.value = const AsyncData(false);
  }
}
