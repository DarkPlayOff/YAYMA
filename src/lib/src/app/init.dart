import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart'
    show accountSignal, appContextSignal, authSignal;
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
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

    final appDir = await _resolveDataDir();
    await simple.initAppInfrastructure(basePath: appDir.path);

    try {
      final settings = await simple.getInitialSettings();
      autoHideNavbarSignal.value = settings.autoHideNavbar;
      closeToTraySignal.value = settings.closeToTray;
      customTitlebarSignal.value = settings.customTitlebar;
      vibeVisibleSignal.value = settings.vibeAnimationEnabled;
      vibeRenderScaleSignal.value = settings.vibeRenderScale;
      blurEffectsEnabledSignal.value = settings.blurEffectsEnabled;
    } on Object catch (_) {}

    unawaited(_initializeAuthAndServices());
  }

  /// Rust backend storage (yamusic_v2.db, http/track caches) lives in the
  /// platform application-support directory, not Documents. One-time move
  /// for installs predating this: the auth token is stored inside the DB,
  /// so moving without migration would log every user out and orphan
  /// downloaded tracks.
  static Future<Directory> _resolveDataDir() async {
    final support = await getApplicationSupportDirectory();
    await _migrateLegacyDataDir(support);
    return support;
  }

  static Future<void> _migrateLegacyDataDir(Directory support) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      if (docs.path == support.path) return;
      final legacyDb = File(
        '${docs.path}${Platform.pathSeparator}yamusic_v2.db',
      );
      if (!legacyDb.existsSync()) return;
      final targetDb = File(
        '${support.path}${Platform.pathSeparator}yamusic_v2.db',
      );
      if (targetDb.existsSync()) return;
      await support.create(recursive: true);
      for (final name in [
        'yamusic_v2.db',
        'yamusic_v2.db-wal',
        'yamusic_v2.db-shm',
        'http_cache',
        'offline_tracks',
      ]) {
        await _moveEntity(docs.path, support.path, name);
      }
    } on Object {
      // Migration is best-effort only; worst case the app starts fresh.
    }
  }

  static Future<void> _moveEntity(
    String fromDir,
    String toDir,
    String name,
  ) async {
    try {
      final srcDir = Directory('$fromDir${Platform.pathSeparator}$name');
      if (srcDir.existsSync()) {
        await srcDir.rename('$toDir${Platform.pathSeparator}$name');
        return;
      }
      final srcFile = File('$fromDir${Platform.pathSeparator}$name');
      if (srcFile.existsSync()) {
        await srcFile.rename('$toDir${Platform.pathSeparator}$name');
      }
    } on Object {
      // Best-effort per entry.
    }
  }

  static Future<void> _initAudioService() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

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

    unawaited(requestIgnoreBatteryOptimizations());
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
