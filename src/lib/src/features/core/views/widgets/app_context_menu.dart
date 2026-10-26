import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/track_context_sheet.dart';

class AppContextMenuItem<T> {
  final T? value;
  final String label;
  final IconData? icon;
  final Widget? leading;
  final Color? color;

  /// Builds the children on each open so they can hold fresh state.
  final List<AppContextMenuItem<T>> Function()? subItems;
  final bool isSelected;

  /// Title of the follow-up sheet; falls back to [label].
  final String? subSheetTitle;

  /// Called when the user opens the nested sheet.
  final VoidCallback? onSubSheetOpen;

  /// Keep the sheet open after the action fires (quick toggles like "like").
  final bool keepOpen;

  const AppContextMenuItem({
    required this.label,
    this.icon,
    this.leading,
    this.value,
    this.color,
    this.subItems,
    this.isSelected = false,
    this.subSheetTitle,
    this.onSubSheetOpen,
    this.keepOpen = false,
  });
}

class AppContextMenu<T> extends StatelessWidget {
  final List<AppContextMenuItem<T>> items;
  final void Function(T value) onSelected;
  final Widget child;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final BorderRadius borderRadius;

  /// Hover/press backdrop color; null keeps the theme default (nearly
  /// invisible). Icon triggers pass an M3-style state layer to match
  /// neighbouring IconButtons.
  final Color? hoverColor;

  const AppContextMenu({
    required this.items,
    required this.onSelected,
    required this.child,
    this.onOpen,
    this.onClose,
    this.borderRadius = const BorderRadius.all(Radius.circular(100)),
    this.hoverColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // Android has no hover/flyout menus: the same actions open as a sheet.
    if (Platform.isAndroid) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            onOpen?.call();
            await showAppActionSheet<T>(
              context,
              actions: items,
              onSelected: onSelected,
            );
            onClose?.call();
          },
          hoverColor: hoverColor,
          highlightColor: hoverColor,
          borderRadius: borderRadius,
          child: child,
        ),
      );
    }

    return MenuAnchor(
      onOpen: onOpen,
      onClose: onClose,
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(
          Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        padding: WidgetStateProperty.all(EdgeInsets.zero),
        elevation: WidgetStateProperty.all(12),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            side: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.1),
            ),
          ),
        ),
      ),
      menuChildren: items.asMap().entries.map((entry) {
        return _buildItem(context, entry.value, entry.key);
      }).toList(),
      builder: (context, controller, child) {
        // Local Material: ink paints at the trigger itself instead of a
        // Material buried under opaque backgrounds (e.g. the player backdrop).
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            hoverColor: hoverColor,
            highlightColor: hoverColor,
            borderRadius: borderRadius,
            child: this.child,
          ),
        );
      },
    );
  }

  Widget _buildItem(
    BuildContext context,
    AppContextMenuItem<T> item,
    int index,
  ) {
    final child = _buildItemContent(context, item, index);

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 300 + (index * 50)),
      curve: Curves.easeOutQuart,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) {
        // Staggered effect: calculate a delayed value based on index
        final startDelay = (index * 0.1).clamp(0.0, 0.5);
        final effectiveValue = ((value - startDelay) / (1.0 - startDelay))
            .clamp(0.0, 1.0);

        return Opacity(
          opacity: effectiveValue,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - effectiveValue)),
            child: Transform.scale(
              scale: 0.95 + (0.05 * effectiveValue),
              child: child,
            ),
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildItemContent(
    BuildContext context,
    AppContextMenuItem<T> item,
    int index,
  ) {
    final leading =
        item.leading ??
        (item.icon != null
            ? Icon(
                item.icon,
                color:
                    item.color ??
                    Theme.of(context).colorScheme.onSurfaceVariant,
                size: 18,
              )
            : null);

    final subItems = item.subItems?.call();

    if (subItems != null && subItems.isNotEmpty) {
      return SubmenuButton(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
          padding: WidgetStateProperty.all(EdgeInsets.zero),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              side: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.1),
              ),
            ),
          ),
        ),
        menuChildren: subItems
            .asMap()
            .entries
            .map((entry) => _buildItem(context, entry.value, entry.key))
            .toList(),
        leadingIcon: leading,
        child: Text(
          item.label,
          style: TextStyle(
            color: item.color ?? Theme.of(context).colorScheme.onSurface,
            fontSize: 14,
          ),
        ),
      );
    }

    return MenuItemButton(
      onPressed: () {
        if (item.value != null) {
          onSelected(item.value as T);
        }
      },
      leadingIcon: leading,
      trailingIcon: item.isSelected
          ? Icon(
              Icons.check_rounded,
              color: item.color ?? Theme.of(context).colorScheme.primary,
              size: 16,
            )
          : null,
      child: Text(
        item.label,
        style: TextStyle(
          color: item.color ?? Theme.of(context).colorScheme.onSurface,
          fontSize: 14,
        ),
      ),
    );
  }
}
