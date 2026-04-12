import 'package:flutter/material.dart';

class AppContextMenuItem<T> {
  final T? value;
  final String label;
  final IconData icon;
  final Color? color;
  final List<AppContextMenuItem<T>>? subItems;

  const AppContextMenuItem({
    required this.label, required this.icon, this.value,
    this.color,
    this.subItems,
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
      menuChildren: items.map((item) => _buildItem(context, item)).toList(),
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

  Widget _buildItem(BuildContext context, AppContextMenuItem<T> item) {
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
        menuChildren: item.subItems!.map((sub) => _buildItem(context, sub)).toList(),
        leadingIcon: const Icon(Icons.chevron_left_rounded, size: 18, color: Colors.white38),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, color: item.color ?? Colors.white70, size: 18),
            const SizedBox(width: 12),
            Text(
              item.label,
              style: TextStyle(color: item.color ?? Colors.white, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return MenuItemButton(
      onPressed: () {
        if (item.value != null) {
          onSelected(item.value as T);
        }
      },
      leadingIcon: Icon(item.icon, color: item.color ?? Colors.white70, size: 18),
      child: Text(
        item.label,
        style: TextStyle(color: item.color ?? Colors.white, fontSize: 14),
      ),
    );
  }
}
