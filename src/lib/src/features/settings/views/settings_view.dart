import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/providers/visual_effects_provider.dart';
import 'package:yayma/src/features/core/services/global_hotkey_service.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/settings/views/lyrics_providers_dialog.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/simple.dart' as simple;

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final FutureSignal<String?> _pathSignal;
  late final FutureSignal<int> _cacheSizeSignal;
  late final FutureSignal<int> _trackCacheSizeSignal;
  late final FutureSignal<String> _versionSignal;
  late final FutureSignal<bool> _discordRpcSignal;
  late final FutureSignal<bool> _customTitlebarSignal;
  late final FutureSignal<bool> _autoHideNavbarSignal;
  late final FutureSignal<bool> _closeToTraySignal;
  late final FutureSignal<bool> _updateCheckSignal;

  @override
  void initState() {
    super.initState();
    _pathSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return await rust.getDownloadPath(ctx: ctx);
    });
    _cacheSizeSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return 0;
      return await simple.getCacheSize(ctx: ctx);
    });
    _trackCacheSizeSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return 0;
      return await simple.getTrackCacheSize(ctx: ctx);
    });
    _versionSignal = futureSignal(() async {
      return await simple.getAppVersion();
    });
    _discordRpcSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return false;
      return await simple.isDiscordRpcEnabled(ctx: ctx);
    });
    _customTitlebarSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return true;
      return await simple.isCustomTitlebarEnabled(ctx: ctx);
    });
    _autoHideNavbarSignal = futureSignal(
      () => Future.value(autoHideNavbarSignal.value),
    );
    _closeToTraySignal = futureSignal(
      () => Future.value(closeToTraySignal.value),
    );
    _updateCheckSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return true;
      return await simple.isUpdateCheckEnabled(ctx: ctx);
    });
  }

  Future<void> _toggleDiscordRpc(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setDiscordRpcEnabled(ctx: ctx, enabled: enabled);
      unawaited(_discordRpcSignal.refresh());
    }
  }

  Future<void> _toggleCustomTitlebar(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setCustomTitlebarEnabled(ctx: ctx, enabled: enabled);
      unawaited(_customTitlebarSignal.refresh());
      showAppSuccess('Изменения вступят в силу после перезапуска приложения');
    }
  }

  Future<void> _toggleAutoHideNavbar(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setAutoHideNavbarEnabled(ctx: ctx, enabled: enabled);
      autoHideNavbarSignal.value = enabled;
      unawaited(_autoHideNavbarSignal.refresh());
    }
  }

  Future<void> _toggleCloseToTray(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setCloseToTrayEnabled(ctx: ctx, enabled: enabled);
      closeToTraySignal.value = enabled;
      unawaited(_closeToTraySignal.refresh());
    }
  }

  Future<void> _toggleUpdateCheck(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setUpdateCheckEnabled(ctx: ctx, enabled: enabled);
      unawaited(_updateCheckSignal.refresh());
    }
  }

  Future<void> _toggleVibeVisibility(bool enabled) async {
    vibeVisibleSignal.value = enabled;
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setVibeAnimationEnabled(ctx: ctx, enabled: enabled);
    }
  }

  Future<void> _saveVibeRenderScale(double scale) async {
    final normalized = scale.clamp(
      minVibeRenderScale,
      maxVibeRenderScale,
    );
    vibeRenderScaleSignal.value = normalized;
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setVibeRenderScale(ctx: ctx, scale: normalized);
    }
  }

  Future<void> _toggleBlurEffects(bool enabled) async {
    blurEffectsEnabledSignal.value = enabled;
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setBlurEffectsEnabled(ctx: ctx, enabled: enabled);
    }
  }

  Future<void> _pickPath() async {
    final result = await FilePicker.getDirectoryPath();
    if (result != null) {
      final ctx = appContextSignal.value;
      if (ctx != null) {
        await rust.setDownloadPath(ctx: ctx, path: result);
        unawaited(_pathSignal.refresh());
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 Б';
    const suffixes = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
    var i = 0;
    var size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _clearCache() async {
    final ctx = appContextSignal.value;
    if (ctx == null) return;
    await simple.clearCache(ctx: ctx);
    unawaited(_cacheSizeSignal.refresh());
    showAppSuccess('Кэш успешно очищен');
  }

  Future<void> _clearTrackCache() async {
    final ctx = appContextSignal.value;
    if (ctx == null) return;
    await simple.clearTrackCache(ctx: ctx);
    unawaited(_trackCacheSizeSignal.refresh());
    // Also notify the downloaded tracks signal
    unawaited(refreshDownloadedTracks());
    showAppSuccess('Скачанные треки успешно удалены');
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                isNarrow ? 20 : 40,
                isNarrow ? 20 : 60,
                isNarrow ? 20 : 40,
                isNarrow ? 20 : 40,
              ),
              child: Text(
                'Настройки',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  fontSize: isNarrow ? 28 : 48,
                  fontWeight: FontWeight.w900,
                  color: cs.onSurface,
                  letterSpacing: -1,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: context.horizontalPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle(title: 'Загрузки'),
                  const SizedBox(height: 20),
                  SignalBuilder(
                    builder: (context) {
                      final path = _pathSignal.value;
                      return _SettingItem(
                        title: 'Путь для сохранения треков',
                        subtitle: path.value ?? 'По умолчанию (Загрузки)',
                        icon: Icons.folder_open_rounded,
                        onTap: () => unawaited(_pickPath()),
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                  const _SectionTitle(title: 'Визуальные эффекты'),
                  const SizedBox(height: 20),
                  SignalBuilder(
                    builder: (context) {
                      final enabled = vibeVisibleSignal.value;
                      return _SettingItem(
                        title: 'Показывать волну',
                        subtitle: 'Динамический фон, реагирующий на музыку',
                        icon: Icons.waves_rounded,
                        onTap: () => unawaited(
                          _toggleVibeVisibility(!enabled),
                        ),
                        trailing: Switch(
                          value: enabled,
                          onChanged: (value) => unawaited(
                            _toggleVibeVisibility(value),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SignalBuilder(
                    builder: (context) {
                      final scale = vibeRenderScaleSignal.value;
                      return _SettingItem(
                        title: 'Разрешение волны',
                        subtitle:
                            '${(scale * 100).round()}% — выше качество, выше нагрузка',
                        icon: Icons.high_quality_rounded,
                        onTap: () {},
                        trailing: SizedBox(
                          width: isNarrow ? 120 : 200,
                          child: Slider(
                            value: scale,
                            min: minVibeRenderScale,
                            max: maxVibeRenderScale,
                            divisions: 5,
                            label: '${(scale * 100).round()}%',
                            onChanged: vibeVisibleSignal.value
                                ? (value) {
                                    vibeRenderScaleSignal.value = value;
                                  }
                                : null,
                            onChangeEnd: (value) => unawaited(
                              _saveVibeRenderScale(value),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SignalBuilder(
                    builder: (context) {
                      final enabled = blurEffectsEnabledSignal.value;
                      return _SettingItem(
                        title: 'Размытие интерфейса',
                        subtitle: 'Размывать фон под панелями управления',
                        icon: Icons.blur_on_rounded,
                        onTap: () => unawaited(
                          _toggleBlurEffects(!enabled),
                        ),
                        trailing: Switch(
                          value: enabled,
                          onChanged: (value) => unawaited(
                            _toggleBlurEffects(value),
                          ),
                        ),
                      );
                    },
                  ),
                  if (context.isDesktop) ...[
                    const SizedBox(height: 32),
                    const _SectionTitle(title: 'Горячие клавиши'),
                    const SizedBox(height: 20),
                    _SettingItem(
                      title: 'Управление горячими клавишами',
                      subtitle:
                          'Глобальные сочетания клавиш, работающие вне окна',
                      icon: Icons.keyboard_command_key_rounded,
                      onTap: () => unawaited(
                        showDialog<void>(
                          context: context,
                          builder: (context) => const _GlobalHotkeysDialog(),
                        ),
                      ),
                    ),
                  ],
                  if (context.isDesktop) ...[
                    const SizedBox(height: 32),
                    const _SectionTitle(title: 'Внешний вид'),
                    const SizedBox(height: 20),
                    SignalBuilder(
                      builder: (context) {
                        final enabled = _customTitlebarSignal.value;
                        return _SettingItem(
                          title: 'Собственная рамка окна',
                          subtitle: 'Отключает стандартную рамку ОС',
                          icon: Icons.web_asset_rounded,
                          onTap: () => unawaited(
                            _toggleCustomTitlebar(!(enabled.value ?? false)),
                          ),
                          trailing: Switch(
                            value: enabled.value ?? false,
                            onChanged: (v) =>
                                unawaited(_toggleCustomTitlebar(v)),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    SignalBuilder(
                      builder: (context) {
                        final enabled = _autoHideNavbarSignal.value;
                        return _SettingItem(
                          title: 'Скрывать боковую панель',
                          subtitle:
                              'Автоматически скрывать навигацию на главном экране',
                          icon: Icons.vertical_split_rounded,
                          onTap: () => unawaited(
                            _toggleAutoHideNavbar(!(enabled.value ?? false)),
                          ),
                          trailing: Switch(
                            value: enabled.value ?? false,
                            onChanged: (v) =>
                                unawaited(_toggleAutoHideNavbar(v)),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                  ],
                  if (context.isDesktop) ...[
                    const _SectionTitle(title: 'Интеграции'),
                    const SizedBox(height: 20),
                    SignalBuilder(
                      builder: (context) {
                        final enabled = _discordRpcSignal.value;
                        return _SettingItem(
                          title: 'Discord Rich Presence',
                          subtitle: 'Показывать текущий трек в статусе Discord',
                          icon: Icons.discord_rounded,
                          onTap: () => unawaited(
                            _toggleDiscordRpc(!(enabled.value ?? true)),
                          ),
                          trailing: Switch(
                            value: enabled.value ?? true,
                            onChanged: (v) => unawaited(_toggleDiscordRpc(v)),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                  ],
                  if (context.isDesktop) ...[
                    const _SectionTitle(title: 'Система'),
                    const SizedBox(height: 20),
                    SignalBuilder(
                      builder: (context) {
                        final enabled = _closeToTraySignal.value;
                        return _SettingItem(
                          title: 'Сворачивать в трей при закрытии',
                          subtitle:
                              'При нажатии на крестик приложение будет скрыто в трей',
                          icon: Icons.window_rounded,
                          onTap: () => unawaited(
                            _toggleCloseToTray(!(enabled.value ?? true)),
                          ),
                          trailing: Switch(
                            value: enabled.value ?? true,
                            onChanged: (v) => unawaited(_toggleCloseToTray(v)),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 32),
                  ],
                  const _SectionTitle(title: 'Тексты песен'),
                  const SizedBox(height: 20),
                  _SettingItem(
                    title: 'Источники текста песен',
                    subtitle:
                        'Включённые источники для поиска синхронного текста, если у ',
                    icon: Icons.lyrics_rounded,
                    onTap: () => LyricsProvidersDialog.show(context),
                  ),
                  const SizedBox(height: 32),
                  const _SectionTitle(title: 'Кэш'),
                  const SizedBox(height: 20),
                  SignalBuilder(
                    builder: (context) {
                      final size = _cacheSizeSignal.value;
                      return _SettingItem(
                        title: 'Очистить кэш изображений и данных',
                        subtitle: size.map(
                          data: (d) => 'Занято: ${_formatBytes(d)}',
                          error: (e, s) => 'Ошибка при получении размера',
                          loading: () => 'Подсчет...',
                        ),
                        icon: Icons.image_not_supported_rounded,
                        onTap: () => unawaited(_clearCache()),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SignalBuilder(
                    builder: (context) {
                      final size = _trackCacheSizeSignal.value;
                      return _SettingItem(
                        title: 'Удалить скачанные треки',
                        subtitle: size.map(
                          data: (d) => 'Занято: ${_formatBytes(d)}',
                          error: (e, s) => 'Ошибка при получении размера',
                          loading: () => 'Подсчет...',
                        ),
                        icon: Icons.music_off_rounded,
                        onTap: () => unawaited(_clearTrackCache()),
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                  const _SectionTitle(title: 'О приложении'),
                  const SizedBox(height: 20),
                  Container(
                    padding: EdgeInsets.all(isNarrow ? 18 : 24),
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(
                        color: cs.onSurface.withValues(alpha: 0.1),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'YAYMA',
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: isNarrow ? 18 : 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SignalBuilder(
                          builder: (context) {
                            final version = _versionSignal.value;
                            return Text(
                              'Альтернативный клиент для Яндекс Музыки.\nВерсия ${version.value ?? '...'}',
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: isNarrow ? 14 : 16,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  SignalBuilder(
                    builder: (context) {
                      final enabled = _updateCheckSignal.value;
                      return _SettingItem(
                        title: 'Проверка обновлений при запуске',
                        subtitle:
                            'Проверять наличие новых версий на GitHub при запуске',
                        icon: Icons.system_update_rounded,
                        onTap: () => unawaited(
                          _toggleUpdateCheck(!(enabled.value ?? true)),
                        ),
                        trailing: Switch(
                          value: enabled.value ?? true,
                          onChanged: (v) => unawaited(_toggleUpdateCheck(v)),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 60)),
        ],
      ),
    );
  }
}

class _GlobalHotkeysSettings extends StatefulWidget {
  const _GlobalHotkeysSettings();

  @override
  State<_GlobalHotkeysSettings> createState() => _GlobalHotkeysSettingsState();
}

class _GlobalHotkeysSettingsState extends State<_GlobalHotkeysSettings> {
  Future<void> _edit(GlobalHotkeyBinding binding) async {
    final hotKey = await showDialog<HotKey>(
      context: context,
      builder: (context) => _HotkeyDialog(binding: binding),
    );
    if (!mounted || hotKey == null) return;

    final conflict = GlobalHotkeyService.conflictFor(binding.action, hotKey);
    if (conflict != null) {
      showAppError(
        'Это сочетание уже назначено для действия «${conflict.action.title}»',
      );
      return;
    }

    await GlobalHotkeyService.updateBinding(binding.action, hotKey);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNarrow = context.isNarrow;

    return ValueListenableBuilder<int>(
      valueListenable: GlobalHotkeyService.changes,
      builder: (context, _, child) {
        final bindings = GlobalHotkeyService.bindings;
        return Container(
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.1)),
          ),
          child: Column(
            children: [
              _HotkeyMasterRow(
                enabled: GlobalHotkeyService.hotkeysEnabled,
                onChanged: (enabled) => unawaited(
                  GlobalHotkeyService.setAllEnabled(enabled: enabled),
                ),
              ),
              Divider(
                height: 1,
                indent: isNarrow ? 16 : 20,
                endIndent: isNarrow ? 16 : 20,
              ),
              for (var i = 0; i < bindings.length; i++) ...[
                _HotkeySettingRow(
                  binding: bindings[i],
                  hotkeysEnabled: GlobalHotkeyService.hotkeysEnabled,
                  onEnabledChanged: (enabled) => unawaited(
                    GlobalHotkeyService.setEnabled(
                      bindings[i].action,
                      enabled: enabled,
                    ),
                  ),
                  onEdit: () => unawaited(_edit(bindings[i])),
                ),
                if (i < bindings.length - 1)
                  Divider(
                    height: 1,
                    indent: isNarrow ? 16 : 20,
                    endIndent: isNarrow ? 16 : 20,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _GlobalHotkeysDialog extends StatefulWidget {
  const _GlobalHotkeysDialog();

  @override
  State<_GlobalHotkeysDialog> createState() => _GlobalHotkeysDialogState();
}

class _GlobalHotkeysDialogState extends State<_GlobalHotkeysDialog> {
  Future<void> _reset() async {
    await GlobalHotkeyService.resetDefaults();
    if (mounted) showAppSuccess('Горячие клавиши сброшены по умолчанию');
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxContentHeight = (screenHeight * 0.82).clamp(360.0, 760.0);

    return AppDialog(
      title: 'Горячие клавиши',
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: maxContentHeight,
        ),
        child: const SingleChildScrollView(
          child: _GlobalHotkeysSettings(),
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => unawaited(_reset()),
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Сбросить по умолчанию'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HotkeyMasterRow extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _HotkeyMasterRow({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNarrow = context.isNarrow;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 12 : 16,
        vertical: isNarrow ? 10 : 12,
      ),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.keyboard_command_key_rounded : Icons.block_rounded,
            color: enabled ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Использовать горячие клавиши',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: isNarrow ? 14 : 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  enabled
                      ? 'Все включённые сочетания активны в системе'
                      : 'Все системные сочетания временно отключены',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: isNarrow ? 12 : 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _HotkeySettingRow extends StatelessWidget {
  final GlobalHotkeyBinding binding;
  final bool hotkeysEnabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onEdit;

  const _HotkeySettingRow({
    required this.binding,
    required this.hotkeysEnabled,
    required this.onEnabledChanged,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNarrow = context.isNarrow;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 12 : 16,
        vertical: isNarrow ? 8 : 10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  binding.action.title,
                  style: TextStyle(
                    color: binding.enabled && hotkeysEnabled
                        ? cs.onSurface
                        : cs.onSurfaceVariant,
                    fontSize: isNarrow ? 14 : 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                InkWell(
                  onTap: onEdit,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: binding.enabled && hotkeysEnabled
                          ? cs.primary.withValues(alpha: 0.12)
                          : cs.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(
                      GlobalHotkeyService.formatHotKey(binding.hotKey),
                      style: TextStyle(
                        color: binding.enabled && hotkeysEnabled
                            ? cs.primary
                            : cs.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Изменить сочетание',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded),
          ),
          Switch(value: binding.enabled, onChanged: onEnabledChanged),
        ],
      ),
    );
  }
}

class _HotkeyDialog extends StatefulWidget {
  final GlobalHotkeyBinding binding;

  const _HotkeyDialog({required this.binding});

  @override
  State<_HotkeyDialog> createState() => _HotkeyDialogState();
}

class _HotkeyDialogState extends State<_HotkeyDialog> {
  late HotKey _hotKey;

  @override
  void initState() {
    super.initState();
    _hotKey = widget.binding.hotKey;
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: widget.binding.action.title,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Нажмите нужное сочетание клавиш'),
            const SizedBox(height: 20),
            Center(
              child: HotKeyRecorder(
                initalHotKey: _hotKey,
                onHotKeyRecorded: (hotKey) {
                  setState(() => _hotKey = hotKey);
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        AppDialog.cancelButton(context),
        FilledButton(
          onPressed: () => Navigator.pop(context, _hotKey),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final isNarrow = context.isNarrow;
    return Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: isNarrow ? 20 : 24,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _SettingItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SettingItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isNarrow = context.isNarrow;
    return InkWell(
      onTap: onTap,
      onHover: (_) {},
      hoverColor: onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isNarrow ? 8 : 12,
          vertical: isNarrow ? 8 : 10,
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(isNarrow ? 8 : 10),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon, color: primaryColor, size: isNarrow ? 20 : 22),
            ),
            SizedBox(width: isNarrow ? 12 : 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: onSurface,
                      fontSize: isNarrow ? 15 : 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: onSurfaceVariant,
                      fontSize: isNarrow ? 12 : 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: isNarrow ? 8 : 12),
            trailing ??
                Icon(
                  Icons.chevron_right_rounded,
                  color: onSurfaceVariant,
                  size: isNarrow ? 22 : 24,
                ),
          ],
        ),
      ),
    );
  }
}
