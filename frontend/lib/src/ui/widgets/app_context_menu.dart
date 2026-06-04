import 'package:flutter/material.dart';

class AppContextMenuItem<T> {
  final T? value;
  final String label;
  final IconData? icon;
  final Widget? leading;
  final Color? color;
  final List<AppContextMenuItem<T>>? subItems;
  final bool isSelected;

  const AppContextMenuItem({
    required this.label,
    this.icon,
    this.leading,
    this.value,
    this.color,
    this.subItems,
    this.isSelected = false,
  });
}

class AppContextMenu<T> extends StatelessWidget {
  final List<AppContextMenuItem<T>> items;
  final void Function(T value) onSelected;
  final Widget child;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;

  const AppContextMenu({
    required this.items,
    required this.onSelected,
    required this.child,
    this.onOpen,
    this.onClose,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      onOpen: onOpen,
      onClose: onClose,
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(const Color(0xFF2A2A2E)),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        padding: WidgetStateProperty.all(EdgeInsets.zero),
        elevation: WidgetStateProperty.all(12),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.white10),
          ),
        ),
      ),
      menuChildren: items.asMap().entries.map((entry) {
        return _buildItem(context, entry.value, entry.key);
      }).toList(),
      builder: (context, controller, child) {
        return InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: this.child,
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
        final effectiveValue = ((value - startDelay) / (1.0 - startDelay)).clamp(0.0, 1.0);

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
    final leading = item.leading ??
        (item.icon != null
            ? Icon(
                item.icon,
                color: item.color ?? Colors.white70,
                size: 18,
              )
            : null);

    if (item.subItems != null && item.subItems!.isNotEmpty) {
      return SubmenuButton(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(const Color(0xFF2A2A2E)),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
          padding: WidgetStateProperty.all(EdgeInsets.zero),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Colors.white10),
            ),
          ),
        ),
        menuChildren: item.subItems!
            .asMap()
            .entries
            .map((entry) => _buildItem(context, entry.value, entry.key))
            .toList(),
        leadingIcon: leading,
        child: Text(
          item.label,
          style: TextStyle(color: item.color ?? Colors.white, fontSize: 14),
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
        style: TextStyle(color: item.color ?? Colors.white, fontSize: 14),
      ),
    );
  }
}
