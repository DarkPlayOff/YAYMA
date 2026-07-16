import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart'
    show accountSignal, appContextSignal, authSignal;
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/playback/providers/audio_focus_manager.dart';
import 'package:yayma/src/features/playback/providers/audio_handler.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/auth.dart';
import 'package:yayma/src/rust/api/simple.dart' as simple;
import 'package:yayma/src/rust/app/context.dart';
import 'package:yayma/src/rust/frb_generated.dart';

// Export for backward compatibility
export 'package:yayma/src/features/auth/providers/auth_provider.dart'
    show initAuth, login, logout;

/// Centralized application initialization module
class AppInit {
  static Future<void> initialize() async {
    SignalsObserver.instance = null;

    await RustLib.init();

    if (Platform.isAndroid) {
      await _initAudioService();
    }

    final appDir = await getApplicationDocumentsDirectory();
    await simple.initAppInfrastructure(basePath: appDir.path);

    try {
      final autoHide = await simple.isAutoHideNavbarEnabledInit();
      autoHideNavbarSignal.value = autoHide;

      final closeToTray = await simple.isCloseToTrayEnabledInit();
      closeToTraySignal.value = closeToTray;

      final customTitlebar = await simple.isCustomTitlebarEnabledInit();
      customTitlebarSignal.value = customTitlebar;
    } on Object catch (_) {}

    unawaited(_initializeAuthAndServices());
  }

  static Future<void> _initAudioService() async {
    final session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidWillPauseWhenDucked: false,
      ),
    );

    await AudioFocusManager.initialize(session);

    await AudioService.init(
      builder: YaymaAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'io.github.darkplayoff.yayma.playback',
        androidNotificationChannelName: 'YAYMA Playback',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: true,
        androidNotificationIcon: 'drawable/ic_notification',
      ),
    );
  }

  static Future<void> _initializeAuthAndServices() async {
    final context = await tryAutoLogin();
    appContextSignal.value = context;

    if (context == null) {
      authSignal.value = const AsyncData(false);
      return;
    }

    // Initialize playback locally before showing UI
    await initPlayback();

    // Fetch network-dependent data in the background
    unawaited(_loadAccountInfo(context));
    unawaited(initLibrary());

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

      await initPlayback();

      unawaited(_loadAccountInfo(context));
      unawaited(initLibrary());

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
