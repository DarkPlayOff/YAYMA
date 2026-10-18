import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// Mouse-wheel scrolling that glides instead of jumping.
///
/// Flutter moves a scroll view by the whole wheel notch in a single frame,
/// which on desktop reads as a jump. A [SmoothScrollController] remembers
/// where a burst of notches is heading and animates towards it, so lists
/// glide the way they do in a browser.
///
/// Everything else — dragging, the scrollbar, the keyboard, [jumpTo] and
/// [animateTo] — behaves exactly like [ScrollController].
///
/// Wrapped around a scroll view by [SmoothScroll].
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

/// A [ScrollPosition] whose wheel input animates towards an accumulating
/// target instead of jumping by a single notch.
class SmoothScrollPosition extends ScrollPositionWithSingleContext {
  SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// How long one notch — or a burst of them — takes to settle.
  static const Duration _duration = Duration(milliseconds: 240);
  static const Curve _curve = Curves.easeOutCubic;

  /// The motion currently running, if any, and where it is heading. Notches
  /// that arrive before it settles extend that same target.
  _WheelScrollActivity? _wheelActivity;
  double _wheelTarget = 0;

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0 ||
        !hasPixels ||
        !hasContentDimensions ||
        maxScrollExtent <= minScrollExtent) {
      super.pointerScroll(delta);
      return;
    }

    final continuing = activity == _wheelActivity;
    final base = continuing ? _wheelTarget : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == base) return;

    _wheelTarget = target;
    final motion = _WheelScrollActivity(
      this,
      from: pixels,
      to: target,
      duration: _duration,
      curve: _curve,
      vsync: context.vsync,
    );
    _wheelActivity = motion;
    beginActivity(motion);
    updateUserScrollDirection(
      delta > 0.0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
  }
}

/// [DrivenScrollActivity] that keeps items tappable while it settles.
class _WheelScrollActivity extends DrivenScrollActivity {
  _WheelScrollActivity(
    super.delegate, {
    required super.from,
    required super.to,
    required super.duration,
    required super.curve,
    required super.vsync,
  });

  @override
  bool get shouldIgnorePointer => false;
}

/// Gives the vertical scroll view it wraps smooth mouse-wheel scrolling.
///
/// Wrap exactly one scroll view — usually a [CustomScrollView], [ListView],
/// [GridView] or [SingleChildScrollView] that does not bring its own
/// [ScrollController]. The controller is handed to it through
/// [PrimaryScrollController], and Flutter keeps scroll views nested deeper
/// from inheriting the same one.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({required this.child, super.key});

  /// The scroll view to smooth.
  final Widget child;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController(debugLabel: 'smooth-scroll');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PrimaryScrollController(
      controller: _controller,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: widget.child,
    );
  }
}
