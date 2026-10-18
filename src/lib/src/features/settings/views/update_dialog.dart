import 'dart:async';
import 'dart:io';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/smooth_scroll.dart';
import 'package:yayma/src/features/settings/services/update_service.dart';

class UpdateDialog extends StatefulWidget {
  final AppUpdateInfo? initialInfo;
  final bool bottomSheet;

  const UpdateDialog({this.initialInfo, this.bottomSheet = false, super.key});

  static void show(BuildContext context, {AppUpdateInfo? initialInfo}) {
    if (Platform.isAndroid) {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(AppRadius.xxl),
            ),
          ),
          builder: (context) => UpdateDialog(
            initialInfo: initialInfo,
            bottomSheet: true,
          ),
        ),
      );
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => UpdateDialog(initialInfo: initialInfo),
      ),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isLoading = false;
  String? _error;
  AppUpdateInfo? _info;
  final _scrollController = SmoothScrollController(debugLabel: 'changelog');

  // Android in-app update state.
  bool _isDownloading = false;
  double? _downloadProgress;
  int _lastProgressStep = -1;
  String? _downloadedPath;
  bool _isInstalling = false;
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    if (widget.initialInfo != null) {
      _info = widget.initialInfo;
    } else {
      unawaited(_checkUpdates());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkUpdates() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final info = await UpdateService.checkForUpdates();
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (info == null) {
          _error =
              'Не удалось проверить обновления. Проверьте интернет-соединение.';
        } else {
          _info = info;
        }
      });
    }
  }

  void _launchUrl(String url) {
    unawaited(
      () async {
        try {
          final uri = Uri.parse(url);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        } on Object catch (e) {
          debugPrint('Error launching browser: $e');
        }
      }(),
    );
  }

  Future<void> _downloadUpdate() async {
    final info = _info;
    if (info == null || _isDownloading) return;

    _lastProgressStep = -1;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadError = null;
      _downloadedPath = null;
    });

    try {
      final asset = await UpdateService.resolveApkAsset(info);
      final file = await UpdateService.downloadApk(
        asset,
        onProgress: (progress) {
          final step = progress == null ? -1 : (progress * 100).round();
          if (step == _lastProgressStep) return;
          _lastProgressStep = step;
          if (mounted) setState(() => _downloadProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 1;
        _downloadedPath = file.path;
      });
    } on Object catch (e) {
      debugPrint('Update download failed: $e');
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = null;
        _downloadError = e is UpdateException
            ? e.message
            : 'Не удалось скачать обновление. Проверьте подключение к интернету и попробуйте снова.';
      });
    }
  }

  Future<void> _installUpdate() async {
    final path = _downloadedPath;
    if (path == null || _isInstalling) return;

    setState(() => _isInstalling = true);
    try {
      final allowed = await UpdateService.canInstallPackages();
      if (!allowed) {
        await UpdateService.requestInstallPermission();
        if (mounted) {
          setState(() => _isInstalling = false);
          showAppError(
            'Разрешите установку приложений из этого источника и нажмите «Установить» снова',
          );
        }
        return;
      }
      await UpdateService.installApk(path);
      if (mounted) setState(() => _isInstalling = false);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _isInstalling = false);
        showAppError('Не удалось запустить установку: $e');
      }
    }
  }

  Widget _buildChangelog(BuildContext context, String changelog) {
    final cs = Theme.of(context).colorScheme;
    final lines = changelog.split('\n');
    final children = <Widget>[];

    for (final line in lines) {
      var trimmed = line.trim();
      if (trimmed.isEmpty) {
        children.add(const SizedBox(height: 8));
        continue;
      }

      Widget lineWidget;

      if (trimmed.startsWith('#')) {
        final depth = trimmed.indexOf(RegExp('[^#]'));
        final titleText = trimmed.substring(depth).trim();
        double fontSize = 18;
        if (depth == 1) fontSize = 20;
        if (depth == 2) fontSize = 16;
        if (depth >= 3) fontSize = 14;

        lineWidget = Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(
            titleText,
            style: TextStyle(
              color: cs.onSurface,
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      } else if (trimmed.startsWith('-') || trimmed.startsWith('*')) {
        var itemText = trimmed.substring(1).trim();
        itemText = itemText.replaceAll('**', '');
        lineWidget = Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '  •  ',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
              Expanded(
                child: Text(
                  itemText,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                ),
              ),
            ],
          ),
        );
      } else {
        trimmed = trimmed.replaceAll('**', '');
        lineWidget = Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            trimmed,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
          ),
        );
      }

      children.add(lineWidget);
    }

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _closeButton(ColorScheme cs) {
    return TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text('Закрыть', style: TextStyle(color: cs.onSurfaceVariant)),
    );
  }

  Widget _browserIconButton(ColorScheme cs, String url) {
    return IconButton(
      onPressed: () => _launchUrl(url),
      icon: const Icon(Icons.open_in_new_rounded, size: 20),
      tooltip: 'Открыть в браузере',
      color: cs.onSurfaceVariant,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildAndroidStatus(ColorScheme cs) {
    if (_isDownloading) {
      final progress = _downloadProgress;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            progress != null
                ? 'Загрузка: ${(progress * 100).toStringAsFixed(0)}%'
                : 'Загрузка...',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ],
      );
    }
    if (_downloadError != null) {
      return Text(
        _downloadError!,
        style: TextStyle(color: cs.error, fontSize: 13),
      );
    }
    if (_downloadedPath != null) {
      return Row(
        children: [
          Icon(Icons.check_circle_rounded, color: cs.tertiary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Обновление загружено и готово к установке',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;

    Widget content;
    var actions = <Widget>[];
    Widget? leadingAction;

    if (_isLoading) {
      content = const SizedBox(
        height: 150,
        child: Center(
          child: M3ELoadingIndicator(),
        ),
      );
    } else if (_error != null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: cs.error,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
            ),
          ],
        ),
      );
      actions = [
        TextButton(
          onPressed: () => unawaited(_checkUpdates()),
          child: Text('Повторить', style: TextStyle(color: primaryColor)),
        ),
        if (!widget.bottomSheet)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Закрыть',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
      ];
    } else if (_info != null) {
      final info = _info!;
      if (info.hasUpdate) {
        content = ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Список изменений в этой версии:',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.maxFinite,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                      color: cs.onSurface.withValues(alpha: 0.1),
                    ),
                  ),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: _buildChangelog(context, info.changelog),
                  ),
                ),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 12),
                _buildAndroidStatus(cs),
              ],
            ],
          ),
        );
        if (Platform.isAndroid) {
          leadingAction = _browserIconButton(cs, info.url);
          if (_downloadedPath != null) {
            actions = [
              ElevatedButton.icon(
                onPressed: _isInstalling ? null : () => unawaited(_installUpdate()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.black,
                ),
                icon: const Icon(Icons.install_mobile_rounded),
                label: const Text(
                  'Установить',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (!widget.bottomSheet) _closeButton(cs),
            ];
          } else {
            actions = [
              ElevatedButton.icon(
                onPressed: _isDownloading
                    ? null
                    : () => unawaited(_downloadUpdate()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.black,
                ),
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  _isDownloading ? 'Загрузка...' : 'Скачать обновление',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (!widget.bottomSheet) _closeButton(cs),
            ];
          }
        } else {
          actions = [
            ElevatedButton(
              onPressed: () => _launchUrl(info.url),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.black,
              ),
              child: const Text(
                'Скачать обновление',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            if (!widget.bottomSheet) _closeButton(cs),
          ];
        }
      } else {
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                color: cs.tertiary,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                'У вас установлена последняя версия',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Текущая версия: ${info.latestVersion}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
              ),
            ],
          ),
        );
        actions = [
          if (!widget.bottomSheet)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Отлично',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
        ];
      }
    } else {
      content = const SizedBox.shrink();
    }

    final titleText = (_info != null && _info!.hasUpdate)
        ? 'Доступно обновление до версии ${_info!.latestVersion}'
        : 'Обновление программы';

    if (widget.bottomSheet) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                ),
                child: Row(
                  children: [
                    Icon(Icons.system_update_rounded, color: cs.onSurface),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        titleText,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: content,
                ),
              ),
              if (actions.isNotEmpty || leadingAction != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    8,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      ?leadingAction,
                      const Spacer(),
                      ...actions,
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return AppDialog(
      title: titleText,
      titleIcon: Icons.system_update_rounded,
      titleStyle: TextStyle(
        color: cs.onSurface,
        fontWeight: FontWeight.bold,
        fontSize: 18,
      ),
      contentWidth: 500,
      content: content,
      actions: actions,
    );
  }
}
