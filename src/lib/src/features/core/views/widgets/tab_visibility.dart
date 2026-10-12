import 'package:flutter/widgets.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// Tells the tab subtree whether it is currently visible.
///
/// Used to freeze background tabs: while a tab is hidden
/// ([isVisible] == false), signal reads via [visibleSignal]
/// go through `peek()` and don't subscribe the `SignalBuilder`, so
/// track/color changes don't rebuild invisible tabs.
/// When the tab is opened, the parent root bucket rebuilds anyway
/// on `currentRootSignal`, the builder re-runs and picks up
/// fresh values through a normal subscription.
class TabVisibility extends InheritedWidget {
  final bool isVisible;

  const TabVisibility({
    required this.isVisible,
    required super.child,
    super.key,
  });

  /// Subscribing read: the builder rebuilds on visibility changes,
  /// which guarantees one fresh rebuild the moment the tab opens.
  static bool of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<TabVisibility>();
    // Outside tabs (player, navbar, dialogs) treat as visible:
    // global chrome must always stay live.
    return widget?.isVisible ?? true;
  }

  @override
  bool updateShouldNotify(TabVisibility oldWidget) =>
      isVisible != oldWidget.isVisible;
}

/// Reads [signal] with a subscription only while the tab is visible.
/// In a hidden tab returns the current value via `peek()`
/// without subscribing, so the `SignalBuilder` doesn't rebuild.
T visibleSignal<T>(BuildContext context, ReadonlySignal<T> signal) {
  if (TabVisibility.of(context)) {
    return signal.value;
  }
  return signal.peek();
}
