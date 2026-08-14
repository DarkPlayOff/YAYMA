import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.initialInfo != null) {
      _info = widget.initialInfo;
    } else {
      unawaited(_checkUpdates());
    }
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;

    Widget content;
    var actions = <Widget>[];

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
                    child: _buildChangelog(context, info.changelog),
                  ),
                ),
              ),
            ],
          ),
        );
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
          if (!widget.bottomSheet)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Закрыть',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
        ];
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
              if (actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    8,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        side: BorderSide(color: cs.onSurface.withValues(alpha: 0.1)),
      ),
      title: Row(
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
      content: SizedBox(
        width: 500,
        child: content,
      ),
      actions: actions,
    );
  }
}
