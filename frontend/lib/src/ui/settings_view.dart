import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/providers/auth_provider.dart';
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
  late final FutureSignal<String> _versionSignal;
  late final FutureSignal<bool> _discordRpcSignal;

  @override
  void initState() {
    super.initState();
    _pathSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return null;
      return rust.getDownloadPath(ctx: ctx);
    });
    _cacheSizeSignal = futureSignal(() async {
      return simple.getCacheSize();
    });
    _versionSignal = futureSignal(() async {
      return simple.getAppVersion();
    });
    _discordRpcSignal = futureSignal(() async {
      final ctx = appContextSignal.value;
      if (ctx == null) return false;
      return simple.isDiscordRpcEnabled(ctx: ctx);
    });
  }

  Future<void> _toggleDiscordRpc(bool enabled) async {
    final ctx = appContextSignal.value;
    if (ctx != null) {
      await simple.setDiscordRpcEnabled(ctx: ctx, enabled: enabled);
      unawaited(_discordRpcSignal.refresh());
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
    await simple.clearCache();
    unawaited(_cacheSizeSignal.refresh());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Кэш успешно очищен'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(40, 60, 40, 40),
              child: Text(
                'Настройки',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: -1,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle(context, 'Загрузки'),
                  const SizedBox(height: 24),
                  Watch((context) {
                    final path = _pathSignal.value;
                    return _buildSettingItem(
                      context,
                      title: 'Путь для сохранения треков',
                      subtitle: path.value ?? 'По умолчанию (Загрузки)',
                      icon: Icons.folder_open_rounded,
                      onTap: () => unawaited(_pickPath()),
                    );
                  }),
                  const SizedBox(height: 48),
                  _buildSectionTitle(context, 'Интеграции'),
                  const SizedBox(height: 24),
                  Watch((context) {
                    final enabled = _discordRpcSignal.value;
                    return _buildSettingItem(
                      context,
                      title: 'Discord Rich Presence',
                      subtitle: 'Показывать текущий трек в статусе Discord',
                      icon: Icons.discord_rounded,
                      onTap: () => unawaited(_toggleDiscordRpc(!(enabled.value ?? true))),
                      trailing: Switch(
                        value: enabled.value ?? true,
                        onChanged: (v) => unawaited(_toggleDiscordRpc(v)),
                      ),
                    );
                  }),
                  const SizedBox(height: 48),
                  _buildSectionTitle(context, 'Кэш'),
                  const SizedBox(height: 24),
                  Watch((context) {
                    final size = _cacheSizeSignal.value;
                    return _buildSettingItem(
                      context,
                      title: 'Очистить кэш изображений и данных',
                      subtitle: size.map(
                        data: (d) => 'Занято: ${_formatBytes(d)}',
                        error: (e, s) => 'Ошибка при получении размера',
                        loading: () => 'Подсчет...',
                      ),
                      icon: Icons.delete_sweep_rounded,
                      onTap: () => unawaited(_clearCache()),
                    );
                  }),
                  const SizedBox(height: 48),
                  _buildSectionTitle(context, 'О приложении'),
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
                        Watch((context) {
                          final version = _versionSignal.value;
                          return Text(
                            'Альтернативный клиент для Яндекс Музыки.\nВерсия ${version.value ?? '...'}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 16,
                            ),
                          );
                        }),
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

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 24,
        fontWeight: FontWeight.w800,
      ),
    );
  }

  Widget _buildSettingItem(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
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
