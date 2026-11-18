import 'package:material_ui/material_ui.dart';

/// Slides a tab in and out when the selected tab changes.
///
/// Material's shared-axis X: the incoming tab comes from the side the selection
/// moved to, the outgoing one leaves the other way, both fading. Android only —
/// desktop keeps the instant swap and its rail navigation.
class TabSlide extends StatefulWidget {
  final bool isVisible;

  /// +1 when the newly selected tab sits to the right of the previous one.
  final int direction;

  final Widget child;

  const TabSlide({
    required this.isVisible,
    required this.direction,
    required this.child,
    super.key,
  });

  @override
  State<TabSlide> createState() => _TabSlideState();
}

class _TabSlideState extends State<TabSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.isVisible ? 1 : 0,
  );

  late final Animation<double> _t = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );

  /// Which way this tab travels, in fractions of its width. Fixed when the
  /// switch starts, so a second tap mid-flight cannot make it jump.
  double _slide = 0;

  @override
  void initState() {
    super.initState();
    _slide = _travel();
  }

  double _travel() => 0.1 * widget.direction * (widget.isVisible ? 1 : -1);

  @override
  void didUpdateWidget(TabSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible == widget.isVisible) return;
    _slide = _travel();
    if (widget.isVisible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Theme platform, not Platform.isAndroid: the same binary has to behave
    // the same way on every Android form factor, and widget tests can pick it.
    if (Theme.of(context).platform != TargetPlatform.android) {
      return Offstage(
        offstage: !widget.isVisible,
        child: TickerMode(enabled: widget.isVisible, child: widget.child),
      );
    }

    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) {
        final t = _t.value;
        return Offstage(
          // An outgoing tab has to stay on stage until it has slid away.
          offstage: t == 0,
          child: TickerMode(
            enabled: widget.isVisible || t > 0,
            child: IgnorePointer(
              // Mid-flight the old tab still covers the new one.
              ignoring: !widget.isVisible,
              child: Opacity(
                opacity: t,
                child: FractionalTranslation(
                  translation: Offset(_slide * (1 - t), 0),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
