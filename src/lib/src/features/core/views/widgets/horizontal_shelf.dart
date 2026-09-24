import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Horizontal shelf with desktop scrolling support.
///
/// A horizontal [ListView] ignores vertical [PointerScrollEvent]s by default
/// and mouse-drag scrolling depends on the ambient [ScrollBehavior], so
/// without this wrapper the shelf is effectively not scrollable with a mouse
/// on desktop (touch scrolling is left untouched). The widget:
/// - forwards wheel deltas (dy + dx, so Shift+wheel works too) into
///   horizontal scroll,
/// - enables dragging with mouse/trackpad/touch explicitly,
/// - shows a bottom scrollbar thumb and previous/next arrows on desktop.
class HorizontalShelf extends StatefulWidget {
  final double height;
  final EdgeInsetsGeometry padding;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  const HorizontalShelf({
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    super.key,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<HorizontalShelf> createState() => _HorizontalShelfState();
}

class _HorizontalShelfState extends State<HorizontalShelf> {
  late final ScrollController _controller;
  bool _canGoBack = false;
  bool _canGoForward = false;

  static bool get _isTouch =>
      Platform.isAndroid || Platform.isIOS || Platform.isFuchsia;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController()..addListener(_syncArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
  }

  @override
  void didUpdateWidget(HorizontalShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncArrows() {
    if (!_controller.hasClients || !mounted) return;
    final pos = _controller.position;
    final back = pos.pixels > pos.minScrollExtent;
    final forward = pos.pixels < pos.maxScrollExtent;
    if (back != _canGoBack || forward != _canGoForward) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    // No horizontal overflow — let vertical scroll pass through to parent.
    if (pos.maxScrollExtent <= pos.minScrollExtent) return;
    final delta = event.scrollDelta.dy + event.scrollDelta.dx;
    if (delta == 0) return;
    final next = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    // At the horizontal edge in the scroll direction — don't trap the wheel,
    // let the parent sliver continue vertical scrolling.
    if (next == pos.pixels) return;
    _controller.jumpTo(next);
  }

  void _step(double direction) {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final step = pos.viewportDimension * 0.8;
    final next = (pos.pixels + direction * step).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    _controller.animateTo(
      next,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _arrowButton(BuildContext context, double direction) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: IconButton(
        onPressed: () => _step(direction),
        tooltip: direction < 0 ? 'Назад' : 'Вперёд',
        icon: Icon(
          direction < 0 ? Icons.chevron_left : Icons.chevron_right,
        ),
        style: IconButton.styleFrom(
          backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.92),
          foregroundColor: cs.onSurface,
          side: BorderSide(color: cs.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = Listener(
      onPointerSignal: _onPointerSignal,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.mouse,
          },
        ),
        child: Scrollbar(
          controller: _controller,
          child: ListView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
      ),
    );

    // Touch platforms: swipe works natively, no arrows needed.
    if (_isTouch) {
      return SizedBox(height: widget.height, child: list);
    }

    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          list,
          if (_canGoBack)
            Positioned(
              left: 4,
              top: 0,
              bottom: 0,
              child: _arrowButton(context, -1),
            ),
          if (_canGoForward)
            Positioned(
              right: 4,
              top: 0,
              bottom: 0,
              child: _arrowButton(context, 1),
            ),
        ],
      ),
    );
  }
}
