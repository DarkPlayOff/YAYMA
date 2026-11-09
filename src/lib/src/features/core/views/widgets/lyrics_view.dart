import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/playback/providers/lyrics_provider.dart';

class LyricsReaderDialog extends StatefulWidget {
  final String trackId;
  final String title;

  /// Mobile layout: rendered inside a modal bottom sheet instead of a dialog.
  final bool bottomSheet;
  final ScrollController? scrollController;

  const LyricsReaderDialog({
    required this.trackId,
    required this.title,
    this.bottomSheet = false,
    this.scrollController,
    super.key,
  });

  static void show(BuildContext context, String trackId, String title) {
    if (Platform.isAndroid) {
      unawaited(
        showAppBottomSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.85,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (context, scrollController) => LyricsReaderDialog(
              trackId: trackId,
              title: title,
              bottomSheet: true,
              scrollController: scrollController,
            ),
          ),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (context) => LyricsReaderDialog(trackId: trackId, title: title),
    );
  }

  @override
  State<LyricsReaderDialog> createState() => _LyricsReaderDialogState();
}

class _LyricsReaderDialogState extends State<LyricsReaderDialog> {
  @override
  Widget build(BuildContext context) {
    return SignalBuilder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        final lyricsAsync = lyricsSignal(widget.trackId).value;

        Widget buildLyrics() {
          return lyricsAsync.map(
            data: (result) {
              final lines = result.items.whereType<LyricLine>().toList();
              if (lines.isEmpty) {
                return Center(
                  child: Text(
                    'Текст отсутствует',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.24),
                      fontSize: 18,
                    ),
                  ),
                );
              }
              return ListView.builder(
                controller: widget.scrollController,
                itemCount: lines.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    lines[index].text,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              );
            },
            loading: () => const CommonLoadingWidget(),
            error: (Object e, _) => CommonErrorWidget(error: e),
          );
        }

        if (widget.bottomSheet) {
          return SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: buildLyrics(),
                  ),
                ),
              ],
            ),
          );
        }

        return AppDialog(
          surfaceTintColor: Colors.transparent,
          titleWidget: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: cs.onSurfaceVariant),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          content: Container(
            width: 650,
            height: 800,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: buildLyrics(),
          ),
        );
      },
    );
  }
}
