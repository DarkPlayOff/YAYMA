import 'dart:async';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart'
    show accountSignal, appContextSignal, authSignal;
import 'package:yayma/src/providers/library_provider.dart';
import 'package:yayma/src/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/auth.dart';
import 'package:yayma/src/rust/app/context.dart';
import 'package:yayma/src/rust/frb_generated.dart';

// Экспорт для обратной совместимости
export 'package:yayma/src/providers/auth_provider.dart'
    show initAuth, login, logout;

/// Централизованный модуль инициализации приложения
class AppInit {
  /// Полная инициализация приложения
  static Future<void> initialize() async {
    WidgetsFlutterBinding.ensureInitialized();
    SignalsObserver.instance = null;
    await RustLib.init();
    unawaited(_initializeAuthAndServices());
  }

  /// Инициализация аутентификации и зависимых сервисов
  static Future<void> _initializeAuthAndServices() async {
    final context = await tryAutoLogin();
    appContextSignal.value = context;

    if (context == null) {
      authSignal.value = const AsyncData(false);
      return;
    }

    // Параллельная инициализация зависимых сервисов
    await Future.wait([
      _loadAccountInfo(context),
      initLibrary(),
      initPlayback(),
    ]);

    authSignal.value = const AsyncData(true);
  }

  /// Загрузка информации об аккаунте
  static Future<void> _loadAccountInfo(AppContext context) async {
    try {
      final account = await getAccountInfo(ctx: context);
      accountSignal.value = account;
    } on Exception {
      accountSignal.value = null;
    }
  }

  /// Вход по токену
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

  /// Выход из аккаунта
  static Future<void> logout() async {
    await clearToken();
    accountSignal.value = null;
    appContextSignal.value = null;
    authSignal.value = const AsyncData(false);
  }
}
