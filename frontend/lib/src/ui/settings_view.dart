import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
import 'package:yayma/src/providers/navigation_provider.dart';
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/simple.dart' as simple;
import 'package:yayma/src/ui/widgets/responsive.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final FutureSignal<String?> _pathSignal;
  late final FutureSignal<int> _cacheSizeSignal;
  late final FutureSignal<String> _versionSignal;
  late final FutureSignal<bool> _discordRpcSignal;
  late final FutureSignal<bool> _customTitlebarSignal;
  late final FutureSignal<bool> _autoHideNavbarSignal;
  late final FutureSignal<bool> _closeToTraySignal;

  @override
  void initState() {
    super.initState();
    _pathSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return rust.getDownloadPath(ctx: ctx);
    });
    _cacheSizeSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return 0;
      return simple.getCacheSize(ctx: ctx);
    });
    _versionSignal = futureSignal(() async {
      return simple.getAppVersion();
    });
    _discordRpcSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return false;
      return simple.isDiscordRpcEnabled(ctx: ctx);
    });
    _customTitlebarSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return true;
      return simple.isCustomTitlebarEnabled(ctx: ctx);
    });
    _autoHideNavbarSignal = futureSignal(() async {
      return autoHideNavbarSignal.value;
    });
    _closeToTraySignal = futureSignal(() async {
      return closeToTraySignal.value;
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

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isNarrow = screenWidth < 600;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                isNarrow ? 20 : 40,
                isNarrow ? 40 : 60,
                isNarrow ? 20 : 40,
                isNarrow ? 20 : 40,
              ),
              child: Text(
                'Настройки',
                style: TextStyle(
                  fontSize: isNarrow ? 32 : 48,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
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
                  const SizedBox(height: 24),
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
                  const SizedBox(height: 48),
                  const _SectionTitle(title: 'Внешний вид'),
                  const SizedBox(height: 24),
                  if (context.isDesktop) ...[
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
                    const SizedBox(height: 16),
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
                    const SizedBox(height: 48),
                  ],
                  if (context.isDesktop) ...[
                    const _SectionTitle(title: 'Интеграции'),
                    const SizedBox(height: 24),
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
                    const SizedBox(height: 48),
                  ],
                  if (context.isDesktop) ...[
                    const _SectionTitle(title: 'Система'),
                    const SizedBox(height: 24),
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
                    const SizedBox(height: 48),
                  ],
                  const _SectionTitle(title: 'Кэш'),
                  const SizedBox(height: 24),
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
                        icon: Icons.delete_sweep_rounded,
                        onTap: () => unawaited(_clearCache()),
                      );
                    },
                  ),
                  const SizedBox(height: 48),
                  const _SectionTitle(title: 'О приложении'),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'YAYMA',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SignalBuilder(
                          builder: (context) {
                            final version = _versionSignal.value;
                            return Text(
                              'Альтернативный клиент для Яндекс Музыки.\nВерсия ${version.value ?? '...'}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 16,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 24,
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: primaryColor, size: 28),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
            trailing ??
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white24,
                  size: 32,
                ),
          ],
        ),
      ),
    );
  }
}
