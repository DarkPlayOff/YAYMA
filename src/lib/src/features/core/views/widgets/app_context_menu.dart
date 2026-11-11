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

class AppContextMenu<T> extends StatefulWidget {
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
  State<AppContextMenu<T>> createState() => _AppContextMenuState<T>();
}

class _AppContextMenuState<T> extends State<AppContextMenu<T>> {
  final GlobalKey _anchorKey = GlobalKey();
  final MenuController _controller = MenuController();
  OverlayEntry? _entry;
  ScrollPosition? _scrollPosition;

  @override
  void dispose() {
    _hideEntry();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppContextMenu<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep an open menu in sync with fresh items (playlists, devices, ...).
    // The parent is mid-build here, so refresh after the frame.
    final entry = _entry;
    if (entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _entry != null) entry.markNeedsBuild();
    });
  }

  void _toggleMenu() {
    if (_controller.isOpen) {
      _controller.close();
    } else {
      _showMenu();
    }
  }

  /// The popup is hosted in the root overlay, not inside the trigger. A menu
  /// opened in place focuses itself, and list wrappers such as M3E segmented
  /// items rebuild their subtree on any focus inside them — that recreated the
  /// row and killed the just-opened menu (it looked like the menu closed by
  /// itself on the first try, then worked on the second).
  void _showMenu() {
    if (_entry != null) return;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));

    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned(
            left: origin.dx,
            top: origin.dy,
            child: MenuAnchor(
              controller: _controller,
              style: _menuStyle(context),
              onClose: () {
                widget.onClose?.call();
                _hideEntry();
              },
              menuChildren: widget.items.asMap().entries.map((entry) {
                return _buildItem(context, entry.value, entry.key);
              }).toList(),
              builder: (context, controller, child) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(_entry!);
    // The popup does not move with the list, so any scroll would leave it
    // hanging over a different row — and the action would hit the old one.
    _scrollPosition = Scrollable.maybeOf(context)?.position;
    _scrollPosition?.addListener(_hideEntry);
    widget.onOpen?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _entry != null) _controller.open();
    });
  }

  void _hideEntry() {
    _scrollPosition?.removeListener(_hideEntry);
    _scrollPosition = null;
    _entry?.remove();
    _entry = null;
  }

  MenuStyle _menuStyle(BuildContext context) {
    return MenuStyle(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // Android has no hover/flyout menus: the same actions open as a sheet.
    if (Platform.isAndroid) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            widget.onOpen?.call();
            await showAppActionSheet<T>(
              context,
              actions: widget.items,
              onSelected: widget.onSelected,
            );
            widget.onClose?.call();
          },
          hoverColor: widget.hoverColor,
          highlightColor: widget.hoverColor,
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      );
    }

    return ExcludeFocus(
      // Local Material: ink paints at the trigger itself instead of a Material
      // buried under opaque backgrounds (e.g. the player backdrop).
      child: Material(
        key: _anchorKey,
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleMenu,
          hoverColor: widget.hoverColor,
          highlightColor: widget.hoverColor,
          borderRadius: widget.borderRadius,
          child: widget.child,
        ),
      ),
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
          widget.onSelected(item.value as T);
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
