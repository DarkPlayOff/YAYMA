import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/core/views/widgets/app_context_menu.dart';

enum DownloadMode { cache, files }

class DownloadTargetMenu extends StatelessWidget {
  final bool compact;
  final bool isLoading;
  final void Function(DownloadMode mode) onSelected;
  final bool enabled;

  const DownloadTargetMenu({
    required this.compact,
    required this.isLoading,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = enabled && !isLoading;
    final child = compact
        ? IconButton(
            icon: isLoading
                ? const M3ECircularWavyProgressIndicator(
                    strokeWidth: 2,
                    size: 18,
                  )
                : const Icon(Icons.download_rounded),
            onPressed: isEnabled ? () {} : null,
            tooltip: 'Скачать',
            style: IconButton.styleFrom(
              minimumSize: const Size(64, 56),
              iconSize: 26,
              backgroundColor: cs.onSurface.withValues(alpha: 0.1),
              foregroundColor: cs.onSurface,
              side: BorderSide(color: cs.outlineVariant),
            ),
          )
        : M3EButton.icon(
            icon: isLoading
                ? const M3ECircularWavyProgressIndicator(
                    strokeWidth: 2,
                    size: 18,
                  )
                : const Icon(Icons.download_rounded),
            label: const Text('Скачать'),
            style: M3EButtonStyle.outlined,
            size: M3EButtonSize.md,
            decoration: M3EButtonDecoration.styleFrom(
              backgroundColor: cs.onSurface.withValues(alpha: 0.1),
              foregroundColor: cs.onSurface,
            ),
            onPressed: isEnabled ? () {} : null,
          );

    return IgnorePointer(
      ignoring: !isEnabled,
      child: AppContextMenu<DownloadMode>(
        items: const [
          AppContextMenuItem(
            value: DownloadMode.cache,
            label: 'В кэш приложения',
            icon: Icons.offline_bolt_rounded,
          ),
          AppContextMenuItem(
            value: DownloadMode.files,
            label: 'В отдельные файлы',
            icon: Icons.file_download_rounded,
          ),
        ],
        onSelected: onSelected,
        child: IgnorePointer(child: child),
      ),
    );
  }
}
