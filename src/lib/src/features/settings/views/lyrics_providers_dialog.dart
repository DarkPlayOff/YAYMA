import 'dart:async';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';

/// Lets the user disable individual lyrics sources. The order they're
/// queried in is fixed (word-synced-capable sources first) and isn't
/// user-editable — this only controls which ones participate at all.
class LyricsProvidersDialog extends StatefulWidget {
  const LyricsProvidersDialog({super.key});

  static void show(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => const LyricsProvidersDialog(),
      ),
    );
  }

  @override
  State<LyricsProvidersDialog> createState() => _LyricsProvidersDialogState();
}

class _LyricsProvidersDialogState extends State<LyricsProvidersDialog> {
  List<LyricsProviderSettingDto>? _providers;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ctx = appContextSignal.value;
    if (ctx == null) return;
    final providers = await rust.getLyricsProviderSettings(ctx: ctx);
    if (mounted) {
      setState(() {
        _providers = providers;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(LyricsProviderSettingDto provider, bool enabled) async {
    final ctx = appContextSignal.value;
    final providers = _providers;
    if (ctx == null || providers == null) return;

    final index = providers.indexWhere((p) => p.id == provider.id);
    if (index == -1) return;

    setState(() {
      _providers = [...providers]
        ..[index] = LyricsProviderSettingDto(
          id: provider.id,
          name: provider.name,
          enabled: enabled,
        );
    });

    await rust.setLyricsProviderEnabled(
      ctx: ctx,
      id: provider.id,
      enabled: enabled,
    );
    clearLyricsCache();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryColor = cs.primary;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        side: BorderSide(color: cs.onSurface.withValues(alpha: 0.1)),
      ),
      title: Row(
        children: [
          Icon(Icons.lyrics_rounded, color: cs.onSurface),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Источники текста песен',
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
        child: _loading
            ? const SizedBox(
                height: 150,
                child: Center(child: M3ELoadingIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Отключённые источники не используются при поиске '
                    'текста. Порядок поиска фиксированный: сначала — '
                    'источники с синхронизацией по словам.',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _providers!.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final provider = _providers![index];

                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: cs.onSurface.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: cs.onSurface.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  provider.name,
                                  style: TextStyle(
                                    color: provider.enabled
                                        ? cs.onSurface
                                        : cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              Switch(
                                value: provider.enabled,
                                activeThumbColor: primaryColor,
                                onChanged: (v) =>
                                    unawaited(_toggle(provider, v)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Закрыть',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
