import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/services/rust_bridge.dart';
import 'package:yayma/src/rust/api/hotkeys.dart' as rust;
import 'package:yayma/src/rust/api/models.dart' as rust;

/// Global hotkeys live entirely in Rust (`src/rust/src/app/hotkeys.rs`):
/// persistence, registration and dispatch to the audio actor / library
/// logic. This service is the settings-side facade over that API — it
/// carries no registration state of its own.
///
/// Replaces the `hotkey_manager` Flutter plugin, which had no Wayland
/// backend.
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

/// A captured combo straight from the recorder widget: the USB HID usage of
/// the physical key plus the held modifiers. Rust maps the usage to a
/// keyboard code and validates the binding.
@immutable
class RecordedHotkey {
  final int usbHidUsage;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;

  const RecordedHotkey({
    required this.usbHidUsage,
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.meta,
  });
}

@immutable
class GlobalHotkeyBinding {
  final GlobalHotkeyAction action;
  final bool enabled;
  /// A `keyboard_types::Code` variant name ("Space", "ArrowLeft", "KeyL").
  final String key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;

  const GlobalHotkeyBinding({
    required this.action,
    required this.enabled,
    required this.key,
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.meta,
  });

  String get formattedCombo => GlobalHotkeyService.formatCombo(
    key: key,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    meta: meta,
  );
}

class GlobalHotkeyService {
  GlobalHotkeyService._();

  static final ValueNotifier<int> _changeNotifier = ValueNotifier(0);
  static List<GlobalHotkeyBinding> _bindings = const [];
  static bool _hotkeysEnabled = false;

  // macOS is intentionally not offered: the Rust side would need the
  // hotkey manager on the main thread there (see src/rust/src/app/hotkeys.rs).
  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  static List<GlobalHotkeyBinding> get bindings => List.unmodifiable(_bindings);

  static ValueListenable<int> get changes => _changeNotifier;

  static bool get hotkeysEnabled => _hotkeysEnabled;

  static Future<void> initialize() async {
    if (!isSupported) return;

    // AppInit запускает авторизацию в фоне (unawaited), поэтому к моменту
    // вызова из main() контекст может быть ещё не готов. Раньше метод молча
    // выходил с пустым состоянием — после рестарта настройки выглядели
    // «несохранёнными». Ждём контекст, затем читаем настройки из Rust.
    for (var i = 0; i < 300 && appContextSignal.value == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await refresh();
  }

  /// Перечитать настройки из Rust (вызывать при открытии экрана настроек,
  /// чтобы подтянуть свежее состояние после рестарта).
  static Future<void> refresh() async {
    if (!isSupported) return;
    if (appContextSignal.value == null) return;

    final settings =
        await runRustFetch<rust.HotkeySettingsDto?>(
          (ctx) => rust.getHotkeySettings(ctx: ctx),
        );
    if (settings == null) return;
    _syncFromRust(settings);
  }

  static Future<void> setAllEnabled({required bool enabled}) async {
    final settings =
        await runRustFetch<rust.HotkeySettingsDto?>(
          (ctx) => rust.setHotkeysEnabled(ctx: ctx, enabled: enabled),
        );
    if (settings == null) return;
    _syncFromRust(settings);
  }

  static Future<void> setEnabled(
    GlobalHotkeyAction action, {
    required bool enabled,
  }) async {
    final settings = await runRustFetch<rust.HotkeySettingsDto?>(
      (ctx) => rust.setHotkeyBindingEnabled(
        ctx: ctx,
        action: action.name,
        enabled: enabled,
      ),
    );
    if (settings == null) return;
    _syncFromRust(settings);
  }

  /// Persist a newly recorded combo. Returns null on success, otherwise a
  /// human-readable reason (combo already taken, key not usable as hotkey).
  static Future<String?> updateBinding(
    GlobalHotkeyAction action,
    RecordedHotkey combo,
  ) async {
    final result = await runRustFetch<rust.HotkeyUpdateResultDto?>(
      (ctx) => rust.setHotkeyBinding(
        ctx: ctx,
        action: action.name,
        usbHidUsage: BigInt.from(combo.usbHidUsage),
        ctrl: combo.ctrl,
        alt: combo.alt,
        shift: combo.shift,
        meta: combo.meta,
      ),
    );
    if (result == null) return 'Не удалось сохранить сочетание';
    if (result.conflictWith case final conflictName?) {
      final conflict = _actionOrNull(conflictName);
      return 'Это сочетание уже назначено для действия '
          '«${conflict?.title ?? conflictName}»';
    }
    if (result.invalidKey) {
      return 'Эта клавиша не может использоваться в сочетании';
    }
    final settings = result.settings;
    if (settings != null) {
      _syncFromRust(settings);
    }
    return null;
  }

  static Future<void> resetDefaults() async {
    final settings =
        await runRustFetch<rust.HotkeySettingsDto?>(
          (ctx) => rust.resetHotkeyDefaults(ctx: ctx),
        );
    if (settings == null) return;
    _syncFromRust(settings);
  }

  /// Unregister everything (called on app quit). Registrations die with the
  /// process anyway; this just makes the shutdown explicit.
  static Future<void> dispose() =>
      runRustAction((ctx) async {
        await rust.disposeHotkeys(ctx: ctx);
      });

  static String formatCombo({
    required String key,
    required bool ctrl,
    required bool alt,
    required bool shift,
    required bool meta,
  }) {
    return [
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Win',
      _formatKey(key),
    ].join(' + ');
  }

  static String _formatKey(String key) {
    return switch (key) {
      'Space' => 'Пробел',
      'ArrowLeft' => '←',
      'ArrowRight' => '→',
      'ArrowUp' => '↑',
      'ArrowDown' => '↓',
      'Escape' => 'Esc',
      'Backquote' => '`',
      'Minus' => '-',
      'Equal' => '=',
      'BracketLeft' => '[',
      'BracketRight' => ']',
      'Backslash' => r'\',
      'Semicolon' => ';',
      'Quote' => "'",
      'Comma' => ',',
      'Period' => '.',
      'Slash' => '/',
      _ => key.startsWith('Key')
          ? key.substring(3)
          : key.startsWith('Digit')
          ? key.substring(5)
          : key,
    };
  }

  static void _syncFromRust(rust.HotkeySettingsDto settings) {
    _hotkeysEnabled = settings.enabled;
    _bindings = [
      for (final dto in settings.bindings)
        if (_actionOrNull(dto.action) case final action?)
          GlobalHotkeyBinding(
            action: action,
            enabled: dto.enabled,
            key: dto.key,
            ctrl: dto.ctrl,
            alt: dto.alt,
            shift: dto.shift,
            meta: dto.meta,
          ),
    ];
    _changeNotifier.value++;
  }

  static GlobalHotkeyAction? _actionOrNull(String name) {
    for (final action in GlobalHotkeyAction.values) {
      if (action.name == name) return action;
    }
    return null;
  }
}
