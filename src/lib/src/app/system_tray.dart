import 'dart:async';
import 'dart:io';

import 'package:signals_flutter/signals_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yayma/src/app/window_placement.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/services/global_hotkey_service.dart';
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
class SystemTrayManager with WindowListener {
  SystemTrayManager._();

  static final SystemTrayManager instance = SystemTrayManager._();

  bool _initialized = false;
  bool _quitting = false;
  EffectCleanup? _menuEffect;
  TrayIcon? _trayIcon;
  Menu? _menu;
  MenuItem? _pauseItem;

  /// Whether the tray is supported on the current platform.
  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    _initialized = true;

    // Intercept the window close button so it hides to tray instead of exiting.
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    final trayIcon = TrayIcon.create();
    if (trayIcon == null) return;
    _trayIcon = trayIcon;

    trayIcon
      ..icon = ImageAsset.fromAsset('assets/icons/tray_icon.ico')
      ..setTooltip('YAYMA')
      // Left click restores the window, right click opens the menu.
      ..setContextMenuTrigger(ContextMenuTrigger.rightClicked)
      ..addListener((event) {
        if (event is TrayIconClickedEvent) unawaited(_showWindow());
      });

    final menu = Menu.create();
    if (menu == null) return;
    _menu = menu;
    _pauseItem = _menuItem('Пауза', PlaybackController.togglePlay);
    menu
      ..addItem(_menuItem('Показать окно', _showWindow))
      ..addSeparator()
      ..addItem(_pauseItem)
      ..addItem(_menuItem('Предыдущий трек', PlaybackController.prev))
      ..addItem(_menuItem('Следующий трек', PlaybackController.next))
      ..addSeparator()
      ..addItem(_menuItem('Закрыть', _quit));
    trayIcon
      ..setContextMenu(menu)
      ..setVisible(true);

    // Keep the pause item in sync with playback ("Pause" while playing,
    // "Resume" while paused). A label assignment updates the visible menu.
    _menuEffect = effect(() {
      final isPlaying = isPlayingSignal();
      _pauseItem?.label = isPlaying ? 'Пауза' : 'Возобновить';
    });
  }

  /// Menu item that runs [onClick] on every click.
  MenuItem _menuItem(String label, Future<void> Function() onClick) {
    return MenuItem.createWithLabelAndType(label, MenuItemType.normal)!
      ..addListener((event) {
        if (event is MenuItemClickedEvent) unawaited(onClick());
      });
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    _quitting = true;
    _menuEffect?.call();
    _menuEffect = null;
    await WindowPlacement.saveNow();
    await GlobalHotkeyService.dispose();
    // Allow the window to actually close now that the user asked to quit.
    await windowManager.setPreventClose(false);
    // Removes the icon; the menu and its items are released with it.
    _trayIcon?.dispose();
    _trayIcon = null;
    _menu?.dispose();
    _menu = null;
    _pauseItem = null;
    await windowManager.close();
  }

  // --- WindowListener -------------------------------------------------------

  @override
  void onWindowClose() {
    if (_quitting) return;

    if (closeToTraySignal.value) {
      // Hide to tray rather than terminating the process.
      unawaited(WindowPlacement.saveNow().then((_) => windowManager.hide()));
    } else {
      unawaited(_quit());
    }
  }
}
