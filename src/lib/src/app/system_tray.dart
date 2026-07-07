import 'dart:async';
import 'dart:io';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

/// Minimize-to-tray support for the desktop build.
///
/// Closing the window hides it to the system tray instead of terminating the
/// process. The tray icon exposes playback controls and a way to restore the
/// window (single left click or the Expand menu item) or quit the app.
///
/// Currently scoped to Windows, mirroring the other Win32-only integrations
/// (taskbar thumbnail buttons). The shipped tray icon asset is a `.ico`, which
/// only the Windows tray accepts.
class SystemTrayManager with TrayListener, WindowListener {
  SystemTrayManager._();

  static final SystemTrayManager instance = SystemTrayManager._();

  static const String _expandKey = 'expand';
  static const String _pauseKey = 'pause';
  static const String _prevKey = 'previous';
  static const String _nextKey = 'next';
  static const String _closeKey = 'close';

  bool _initialized = false;
  bool _quitting = false;
  EffectCleanup? _menuEffect;

  /// Whether the tray is supported on the current platform.
  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    _initialized = true;

    // Intercept the window close button so it hides to tray instead of exiting.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    trayManager.addListener(this);
    await trayManager.setIcon('assets/icons/tray_icon.ico');
    await trayManager.setToolTip('YAYMA');

    // Rebuild the context menu whenever playback state changes so the pause
    // item reflects it ("Pause" while playing, "Resume" while paused).
    _menuEffect = effect(() {
      final isPlaying = isPlayingSignal();
      unawaited(trayManager.setContextMenu(_buildMenu(isPlaying: isPlaying)));
    });
  }

  Menu _buildMenu({required bool isPlaying}) {
    return Menu(
      items: [
        MenuItem(key: _expandKey, label: 'Показать окно'),
        MenuItem.separator(),
        MenuItem(key: _pauseKey, label: isPlaying ? 'Пауза' : 'Возобновить'),
        MenuItem(key: _prevKey, label: 'Предыдущий трек'),
        MenuItem(key: _nextKey, label: 'Следующий трек'),
        MenuItem.separator(),
        MenuItem(key: _closeKey, label: 'Закрыть'),
      ],
    );
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    _menuEffect?.call();
    _menuEffect = null;
    // Allow the window to actually close now that the user asked to quit.
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await windowManager.destroy();
  }

  // --- TrayListener ---------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    // Single left click restores the window.
    unawaited(_showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // bringAppToFront makes the owning window foreground before TrackPopupMenu,
    // which is required on Windows for the menu to dismiss on an outside click
    // (classic Win32 notification-icon menu behaviour, MS KB Q135788).
    unawaited(trayManager.popUpContextMenu(bringAppToFront: true));
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _expandKey:
        unawaited(_showWindow());
      case _pauseKey:
        unawaited(PlaybackController.togglePlay());
      case _prevKey:
        unawaited(PlaybackController.prev());
      case _nextKey:
        unawaited(PlaybackController.next());
      case _closeKey:
        unawaited(_quit());
    }
  }

  // --- WindowListener -------------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;

    if (closeToTraySignal.value) {
      // Hide to tray rather than terminating the process.
      unawaited(windowManager.hide());
    } else {
      unawaited(_quit());
    }
  }
}
