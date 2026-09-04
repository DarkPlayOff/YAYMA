import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';

enum GlobalHotkeyAction {
  playPause,
  previousTrack,
  nextTrack,
  seekBackward,
  seekForward,
  likeTrack,
  dislikeTrack;

  String get title => switch (this) {
    GlobalHotkeyAction.playPause => 'Воспроизведение и пауза',
    GlobalHotkeyAction.previousTrack => 'Предыдущий трек',
    GlobalHotkeyAction.nextTrack => 'Следующий трек',
    GlobalHotkeyAction.seekBackward => 'Перемотка назад на 5 секунд',
    GlobalHotkeyAction.seekForward => 'Перемотка вперёд на 5 секунд',
    GlobalHotkeyAction.likeTrack => 'Лайк текущего трека',
    GlobalHotkeyAction.dislikeTrack => 'Дизлайк текущего трека',
  };
}

@immutable
class GlobalHotkeyBinding {
  final GlobalHotkeyAction action;
  final HotKey hotKey;
  final bool enabled;

  const GlobalHotkeyBinding({
    required this.action,
    required this.hotKey,
    required this.enabled,
  });

  GlobalHotkeyBinding copyWith({HotKey? hotKey, bool? enabled}) {
    return GlobalHotkeyBinding(
      action: action,
      hotKey: hotKey ?? this.hotKey,
      enabled: enabled ?? this.enabled,
    );
  }
}

class _LoadedHotkeySettings {
  final bool enabled;
  final List<GlobalHotkeyBinding> bindings;

  const _LoadedHotkeySettings({
    required this.enabled,
    required this.bindings,
  });
}

class GlobalHotkeyService {
  GlobalHotkeyService._();

  static final _registeredHotKeys = <HotKey>[];
  static final ValueNotifier<int> _changeNotifier = ValueNotifier(0);
  static List<GlobalHotkeyBinding> _bindings = _defaultBindings();
  static bool _hotkeysEnabled = false;
  static bool _initialized = false;

  static bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static List<GlobalHotkeyBinding> get bindings => List.unmodifiable(_bindings);

  static ValueListenable<int> get changes => _changeNotifier;

  static bool get hotkeysEnabled => _hotkeysEnabled;

  static Future<void> initialize() async {
    if (!isSupported) return;

    final settings = await _loadSettings();
    _bindings = settings.bindings;
    _hotkeysEnabled = settings.enabled;
    await _applyBindings();
    _initialized = true;
    _notifyChanged();
  }

  static Future<void> setAllEnabled({required bool enabled}) async {
    _hotkeysEnabled = enabled;
    await _saveSettings();
    await _applyBindings();
    _notifyChanged();
  }

  static Future<void> setEnabled(
    GlobalHotkeyAction action, {
    required bool enabled,
  }) async {
    _replaceBinding(action, (binding) => binding.copyWith(enabled: enabled));
    await _saveSettings();
    await _applyBindings();
    _notifyChanged();
  }

  static Future<void> updateBinding(
    GlobalHotkeyAction action,
    HotKey hotKey,
  ) async {
    final normalized = _withActionIdentifier(action, hotKey);
    _replaceBinding(action, (binding) => binding.copyWith(hotKey: normalized));
    await _saveSettings();
    await _applyBindings();
    _notifyChanged();
  }

  static Future<void> resetDefaults() async {
    _bindings = _defaultBindings();
    _hotkeysEnabled = false;
    await _saveSettings();
    await _applyBindings();
    _notifyChanged();
  }

  static GlobalHotkeyBinding? conflictFor(
    GlobalHotkeyAction action,
    HotKey hotKey,
  ) {
    for (final binding in _bindings) {
      if (binding.action != action && _sameHotKey(binding.hotKey, hotKey)) {
        return binding;
      }
    }
    return null;
  }

  static String formatHotKey(HotKey hotKey) {
    final modifiers = hotKey.modifiers ?? const <HotKeyModifier>[];
    final modifierNames = modifiers.map((modifier) {
      return switch (modifier) {
        HotKeyModifier.alt => 'Alt',
        HotKeyModifier.capsLock => 'Caps Lock',
        HotKeyModifier.control => Platform.isMacOS ? '⌃' : 'Ctrl',
        HotKeyModifier.fn => 'Fn',
        HotKeyModifier.meta => Platform.isMacOS ? '⌘' : 'Win',
        HotKeyModifier.shift => 'Shift',
      };
    });
    return [...modifierNames, _formatKey(hotKey.physicalKey)].join(' + ');
  }

  static Future<void> dispose() async {
    if (!_initialized && _registeredHotKeys.isEmpty) return;

    await hotKeyManager.unregisterAll();
    _registeredHotKeys.clear();
    _initialized = false;
  }

  static List<GlobalHotkeyBinding> _defaultBindings() {
    final modifiers = Platform.isMacOS
        ? [HotKeyModifier.meta, HotKeyModifier.alt]
        : [HotKeyModifier.control, HotKeyModifier.alt];
    final seekModifiers = [...modifiers, HotKeyModifier.shift];

    return [
      _binding(
        GlobalHotkeyAction.playPause,
        PhysicalKeyboardKey.space,
        modifiers,
      ),
      _binding(
        GlobalHotkeyAction.previousTrack,
        PhysicalKeyboardKey.arrowLeft,
        modifiers,
      ),
      _binding(
        GlobalHotkeyAction.nextTrack,
        PhysicalKeyboardKey.arrowRight,
        modifiers,
      ),
      _binding(
        GlobalHotkeyAction.seekBackward,
        PhysicalKeyboardKey.arrowLeft,
        seekModifiers,
      ),
      _binding(
        GlobalHotkeyAction.seekForward,
        PhysicalKeyboardKey.arrowRight,
        seekModifiers,
      ),
      _binding(
        GlobalHotkeyAction.likeTrack,
        PhysicalKeyboardKey.keyL,
        modifiers,
      ),
      _binding(
        GlobalHotkeyAction.dislikeTrack,
        PhysicalKeyboardKey.keyD,
        modifiers,
      ),
    ];
  }

  static GlobalHotkeyBinding _binding(
    GlobalHotkeyAction action,
    PhysicalKeyboardKey key,
    List<HotKeyModifier> modifiers,
  ) {
    return GlobalHotkeyBinding(
      action: action,
      hotKey: _withActionIdentifier(
        action,
        HotKey(key: key, modifiers: modifiers),
      ),
      enabled: true,
    );
  }

  static HotKey _withActionIdentifier(
    GlobalHotkeyAction action,
    HotKey hotKey,
  ) {
    return HotKey(
      identifier: 'yayma.global.${action.name}',
      key: hotKey.physicalKey,
      modifiers: hotKey.modifiers ?? const <HotKeyModifier>[],
    );
  }

  static Future<_LoadedHotkeySettings> _loadSettings() async {
    final defaults = _defaultBindings();
    try {
      final file = await _settingsFile();
      if (!file.existsSync()) {
        return _LoadedHotkeySettings(enabled: false, bindings: defaults);
      }

      final decoded = jsonDecode(await file.readAsString());
      final entries = switch (decoded) {
        List<dynamic>() => decoded,
        Map<String, dynamic>() when decoded['bindings'] is List =>
          decoded['bindings'] as List<dynamic>,
        _ => null,
      };
      if (entries == null) {
        return _LoadedHotkeySettings(enabled: false, bindings: defaults);
      }
      final enabled = decoded is Map && decoded['enabled'] == true;

      final saved = <GlobalHotkeyAction, GlobalHotkeyBinding>{};
      for (final entry in entries) {
        if (entry is! Map) continue;
        final actionName = entry['action'];
        final action = GlobalHotkeyAction.values.firstWhereOrNull(
          (item) => item.name == actionName,
        );
        final hotKeyJson = entry['hotKey'];
        if (action == null || hotKeyJson is! Map) continue;

        try {
          final hotKey = HotKey.fromJson(
            Map<String, dynamic>.from(hotKeyJson),
          );
          saved[action] = GlobalHotkeyBinding(
            action: action,
            hotKey: _withActionIdentifier(action, hotKey),
            enabled: entry['enabled'] != false,
          );
        } on Object catch (error) {
          debugPrint('Could not load hotkey ${action.name}: $error');
        }
      }

      return _LoadedHotkeySettings(
        enabled: enabled,
        bindings: [
          for (final fallback in defaults) saved[fallback.action] ?? fallback,
        ],
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Could not load global hotkeys: $error');
      debugPrintStack(stackTrace: stackTrace);
      return _LoadedHotkeySettings(enabled: false, bindings: defaults);
    }
  }

  static Future<void> _saveSettings() async {
    try {
      final file = await _settingsFile();
      await file.writeAsString(
        jsonEncode({
          'enabled': _hotkeysEnabled,
          'bindings': [
            for (final binding in _bindings)
              {
                'action': binding.action.name,
                'enabled': binding.enabled,
                'hotKey': binding.hotKey.toJson(),
              },
          ],
        }),
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Could not save global hotkeys: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static Future<File> _settingsFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File(p.join(directory.path, 'global_hotkeys.json'));
  }

  static Future<void> _applyBindings() async {
    // Makes hot reload and changing a setting safe by removing stale handlers.
    await hotKeyManager.unregisterAll();
    _registeredHotKeys.clear();

    if (!_hotkeysEnabled) return;

    for (final binding in _bindings) {
      if (!binding.enabled) continue;
      await _register(binding);
    }
  }

  static Future<void> _register(GlobalHotkeyBinding binding) async {
    try {
      await hotKeyManager.register(
        binding.hotKey,
        keyDownHandler: (_) {
          final result = _handle(binding.action);
          if (result is Future<void>) unawaited(result);
        },
      );
      _registeredHotKeys.add(binding.hotKey);
    } on Object catch (error, stackTrace) {
      // A system shortcut may already belong to another application.
      debugPrint('Could not register ${binding.hotKey.debugName}: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static FutureOr<void> _handle(GlobalHotkeyAction action) {
    return switch (action) {
      GlobalHotkeyAction.playPause => PlaybackController.togglePlay(),
      GlobalHotkeyAction.previousTrack => PlaybackController.prev(),
      GlobalHotkeyAction.nextTrack => PlaybackController.next(),
      GlobalHotkeyAction.seekBackward => _seekBy(
        const Duration(seconds: -5),
      ),
      GlobalHotkeyAction.seekForward => _seekBy(const Duration(seconds: 5)),
      GlobalHotkeyAction.likeTrack => _toggleLikeCurrent(),
      GlobalHotkeyAction.dislikeTrack => _toggleDislikeCurrent(),
    };
  }

  static Future<void> _toggleLikeCurrent() async {
    final trackId = trackMetadataSignal.value.id;
    if (trackId != null) {
      await PlaybackController.toggleLike(trackId: trackId);
    }
  }

  static Future<void> _toggleDislikeCurrent() async {
    final trackId = trackMetadataSignal.value.id;
    if (trackId != null) {
      await PlaybackController.toggleDislike(trackId: trackId);
    }
  }

  static Future<void> _seekBy(Duration offset) async {
    final progress = trackProgressSignal.value;
    final targetMs = (progress.positionMs + offset.inMilliseconds)
        .clamp(0, progress.durationMs)
        .round();
    await PlaybackController.seekTo(Duration(milliseconds: targetMs));
  }

  static void _replaceBinding(
    GlobalHotkeyAction action,
    GlobalHotkeyBinding Function(GlobalHotkeyBinding) update,
  ) {
    _bindings = [
      for (final binding in _bindings)
        if (binding.action == action) update(binding) else binding,
    ];
  }

  static bool _sameHotKey(HotKey first, HotKey second) {
    if (first.physicalKey.usbHidUsage != second.physicalKey.usbHidUsage) {
      return false;
    }
    final firstModifiers = first.modifiers ?? const <HotKeyModifier>[];
    final secondModifiers = second.modifiers ?? const <HotKeyModifier>[];
    return firstModifiers.length == secondModifiers.length &&
        firstModifiers.every(secondModifiers.contains);
  }

  static String _formatKey(PhysicalKeyboardKey key) {
    return switch (key) {
      PhysicalKeyboardKey.space => 'Пробел',
      PhysicalKeyboardKey.arrowLeft => '←',
      PhysicalKeyboardKey.arrowRight => '→',
      PhysicalKeyboardKey.arrowUp => '↑',
      PhysicalKeyboardKey.arrowDown => '↓',
      _ => key.debugName ?? key.toString(),
    };
  }

  static void _notifyChanged() {
    _changeNotifier.value++;
  }
}

extension on Iterable<GlobalHotkeyAction> {
  GlobalHotkeyAction? firstWhereOrNull(
    bool Function(GlobalHotkeyAction item) test,
  ) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}
