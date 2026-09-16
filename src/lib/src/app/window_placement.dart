import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Persists desktop window position, size and maximized state across restarts.
/// Restore is validated against the currently connected displays: if the
/// saved position is no longer visible (monitor unplugged, layout changed)
/// only the size is kept and the window is centered. On Wayland the
/// compositor owns window positioning, so only size/maximized are restored.
class WindowPlacement {
  WindowPlacement._();

  static const String _fileName = 'window_geometry.json';
  static const String _legacyFileName = 'window_geometry.json';
  static const Size defaultSize = Size(1280, 720);
  static const Size minimumSize = Size(800, 600);

  /// How much of the window must land on a visible display area to keep
  /// the saved position instead of falling back to centering.
  static const double _minVisibleWidth = 100;
  static const double _minVisibleHeight = 50;

  static final _Tracker _tracker = _Tracker();

  /// Saved geometry validated against connected displays, or null when
  /// nothing usable was stored.
  static Future<Rect?> loadBounds() async {
    final data = await _read();
    if (data == null) return null;
    final width = _toDouble(data['width']);
    final height = _toDouble(data['height']);
    final x = _toDouble(data['x']);
    final y = _toDouble(data['y']);
    if (width == null || height == null) return null;
    if (width < minimumSize.width ||
        height < minimumSize.height ||
        width > 7680 ||
        height > 4320) {
      return null;
    }
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return Rect.fromLTWH(x, y, width, height);
  }

  static Future<bool> loadMaximized() async {
    final data = await _read();
    return data?['maximized'] == true;
  }

  /// Saved size regardless of position validity. Used on Wayland and as a
  /// fallback when the saved monitor is gone.
  static Future<Size?> loadSize() async {
    final bounds = await loadBounds();
    return bounds?.size;
  }

  /// Whether the saved position is actually visible on a connected display.
  static Future<bool> isPositionVisible(Rect bounds) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final display in displays) {
        final area = _visibleArea(display);
        if (area == null) continue;
        final intersection = area.intersect(bounds);
        if (intersection.width >= _minVisibleWidth &&
            intersection.height >= _minVisibleHeight) {
          return true;
        }
      }
      return false;
    } on Object {
      // If displays can't be enumerated, trust the saved position rather
      // than forcing a center that might itself be wrong.
      return true;
    }
  }

  /// True on Wayland, where the compositor ignores absolute positioning.
  static bool get isWayland =>
      Platform.isLinux && Platform.environment.containsKey('WAYLAND_DISPLAY');

  /// Start auto-saving on move/resize/maximize. Call once after the window
  /// is shown; safe to call multiple times.
  static void track() {
    _tracker.attach();
  }

  /// Persist the current geometry immediately (e.g. before hide/quit).
  static Future<void> saveNow() => _tracker.saveNow();

  static Rect? _visibleArea(Display display) {
    final position = display.visiblePosition;
    final size = display.visibleSize ?? display.size;
    if (position == null) {
      // No origin reported: assume a single primary display at (0, 0).
      return Rect.fromLTWH(0, 0, size.width, size.height);
    }
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  static Future<Map<String, dynamic>?> _read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        await _migrateLegacy();
        if (!file.existsSync()) return null;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on Object {
      return null;
    }
  }

  static Future<void> _write(Map<String, dynamic> data) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      // Write atomically so a crash mid-save can't leave half a JSON file.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data));
      await tmp.rename(file.path);
    } on Object {
      // Geometry persistence is best-effort; never break shutdown over it.
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  /// One-time move from the previous Documents-based location.
  static Future<void> _migrateLegacy() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final legacy = File(
        '${docs.path}${Platform.pathSeparator}$_legacyFileName',
      );
      if (!legacy.existsSync()) return;
      final target = await _file();
      if (target.existsSync()) {
        await legacy.delete();
        return;
      }
      await target.parent.create(recursive: true);
      await legacy.rename(target.path);
    } on Object {
      // Migration is best-effort only.
    }
  }

  static double? _toDouble(Object? value) {
    if (value is num) {
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }
    return null;
  }

  static Future<void> persistBounds(
    Rect bounds, {
    required bool maximized,
  }) async {
    await _write({
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
      'maximized': maximized,
    });
  }
}

class _Tracker with WindowListener {
  bool _attached = false;
  Timer? _debounce;
  Rect? _lastNormalBounds;

  void attach() {
    if (_attached) return;
    _attached = true;
    windowManager.addListener(this);
    // Capture the initial (restored or default) bounds as the normal state.
    unawaited(_captureInitial());
  }

  Future<void> _captureInitial() async {
    try {
      if (!await windowManager.isMaximized()) {
        _lastNormalBounds = await windowManager.getBounds();
      }
    } on Object {
      // Ignore; first move/resize will populate it.
    }
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(saveNow());
    });
  }

  Future<void> saveNow() async {
    try {
      if (await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        // Transient states must not overwrite the good geometry.
        return;
      }
      final maximized = await windowManager.isMaximized();
      if (maximized) {
        // getBounds() while maximized returns the fullscreen rect, so keep
        // the last normal bounds and only flip the maximized flag.
        final normal = _lastNormalBounds;
        if (normal != null) {
          await WindowPlacement.persistBounds(normal, maximized: true);
        } else {
          final data = await WindowPlacement._read();
          if (data != null) {
            data['maximized'] = true;
            await WindowPlacement._write(data);
          }
        }
        return;
      }
      final bounds = await windowManager.getBounds();
      if (bounds.width < WindowPlacement.minimumSize.width ||
          bounds.height < WindowPlacement.minimumSize.height) {
        return;
      }
      _lastNormalBounds = bounds;
      await WindowPlacement.persistBounds(bounds, maximized: false);
    } on Object {
      // Best-effort only.
    }
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMaximize() => unawaited(saveNow());

  @override
  void onWindowUnmaximize() => unawaited(saveNow());

  @override
  void onWindowClose() => unawaited(saveNow());
}
