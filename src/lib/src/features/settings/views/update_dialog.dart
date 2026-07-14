import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yayma/src/features/settings/services/update_service.dart';

class UpdateDialog extends StatefulWidget {
  final AppUpdateInfo? initialInfo;

  const UpdateDialog({this.initialInfo, super.key});

  static void show(BuildContext context, {AppUpdateInfo? initialInfo}) {
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

  Widget _buildChangelog(String changelog) {
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
              color: Colors.white,
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
              const Text(
                '  •  ',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
              Expanded(
                child: Text(
                  itemText,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
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
            style: const TextStyle(color: Colors.white70, fontSize: 14),
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
    final primaryColor = Theme.of(context).colorScheme.primary;

    Widget content;
    var actions = <Widget>[];

    if (_isLoading) {
      content = const SizedBox(
        height: 150,
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    } else if (_error != null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.redAccent,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      );
      actions = [
        TextButton(
          onPressed: () => unawaited(_checkUpdates()),
          child: Text('Повторить', style: TextStyle(color: primaryColor)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть', style: TextStyle(color: Colors.white54)),
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
              const Text(
                'Список изменений в этой версии:',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.maxFinite,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SingleChildScrollView(
                    child: _buildChangelog(info.changelog),
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Скачать обновление',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Закрыть',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ];
      } else {
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                color: Colors.greenAccent,
                size: 48,
              ),
              const SizedBox(height: 16),
              const Text(
                'У вас установлена последняя версия',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Текущая версия: ${info.latestVersion}',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        );
        actions = [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Отлично',
              style: TextStyle(color: Colors.white54),
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

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Colors.white10),
      ),
      title: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              titleText,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
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
