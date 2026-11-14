import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
class SystemTrayManager {
  SystemTrayManager._();

  static final SystemTrayManager instance = SystemTrayManager._();

  Window? get _window => WindowManager.instance.getCurrent();

  bool _initialized = false;
  bool _quitting = false;
  EffectCleanup? _menuEffect;
  TrayIcon? _trayIcon;
  Menu? _menu;
  MenuItem? _pauseItem;

  /// The runner asks for a real quit here when the console is closed or Ctrl+C
  /// is pressed; WM_CLOSE cannot be used because close-to-tray intercepts it.
  static const MethodChannel _lifecycleChannel =
      MethodChannel('yayma/lifecycle');

  /// Whether the tray is supported on the current platform.
  static bool get isSupported => Platform.isWindows;

  Future<void> initialize() async {
    // Registered before the bail-outs below: quitting must work even when the
    // tray icon could not be created.
    _lifecycleChannel.setMethodCallHandler((call) async {
      if (call.method == 'quit') await quit();
    });

    if (_initialized || !isSupported) return;

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
    if (menu == null) {
      trayIcon.dispose();
      _trayIcon = null;
      return;
    }
    _menu = menu;
    _pauseItem = _menuItem('Пауза', PlaybackController.togglePlay);
    menu
      ..addItem(_menuItem('Показать окно', _showWindow))
      ..addSeparator()
      ..addItem(_pauseItem)
      ..addItem(_menuItem('Предыдущий трек', PlaybackController.prev))
      ..addItem(_menuItem('Следующий трек', PlaybackController.next))
      ..addSeparator()
      ..addItem(_menuItem('Закрыть', quit));
    trayIcon
      ..setContextMenu(menu)
      ..setVisible(true);

    // Keep the pause item in sync with playback ("Pause" while playing,
    // "Resume" while paused). A label assignment updates the visible menu.
    _menuEffect = effect(() {
      final isPlaying = isPlayingSignal();
      _pauseItem?.label = isPlaying ? 'Пауза' : 'Возобновить';
    });

    // Only claim close-to-tray once the icon really exists; otherwise closing
    // the window would hide the app with no way to bring it back.
    _window?.addListener(_onWindowEvent);
    _initialized = true;
  }

  /// Menu item that runs [onClick] on every click.
  MenuItem _menuItem(String label, Future<void> Function() onClick) {
    return MenuItem.createWithLabelAndType(label, MenuItemType.normal)!
      ..addListener((event) {
        if (event is MenuItemClickedEvent) unawaited(onClick());
      });
  }

  Future<void> _showWindow() async {
    _window?.show();
    _window?.focus();
  }

  /// Quits the app: saves the window placement, releases the hotkeys and tray,
  /// then closes the window for real (close-to-tray no longer applies).
  Future<void> quit() async {
    _quitting = true;
    _menuEffect?.call();
    _menuEffect = null;
    await WindowPlacement.saveNow();
    await GlobalHotkeyService.dispose();
    // Removes the icon; the menu and its items are released with it.
    _trayIcon?.dispose();
    _trayIcon = null;
    _menu?.dispose();
    _menu = null;
    _pauseItem = null;
    _window?.close();
  }

  void _onWindowEvent(WindowEvent event) {
    if (event is! WindowCloseRequestedEvent) return;

    if (_quitting) return; // The close that ends the process goes through.

    // Hold the window open; either hide it to the tray or close it ourselves.
    event.request.cancel();
    if (closeToTraySignal.value) {
      // Hide to tray rather than terminating the process.
      unawaited(WindowPlacement.saveNow().then((_) => _window?.hide()));
    } else {
      unawaited(quit());
    }
  }
}
