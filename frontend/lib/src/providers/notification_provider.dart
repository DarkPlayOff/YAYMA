import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class AppNotification {
  final String message;
  final bool isError;
  final DateTime timestamp;

  AppNotification({required this.message, this.isError = true})
    : timestamp = DateTime.now();
}

final FlutterSignal<AppNotification?> appNotificationSignal =
    signal<AppNotification?>(null);

void showAppError(String message) {
  appNotificationSignal.value = AppNotification(message: message);
}

void showAppSuccess(String message) {
  appNotificationSignal.value = AppNotification(
    message: message,
    isError: false,
  );
}

class GlobalNotificationListener extends StatefulWidget {
  final Widget child;
  const GlobalNotificationListener({required this.child, super.key});

  @override
  State<GlobalNotificationListener> createState() =>
      _GlobalNotificationListenerState();
}

class _GlobalNotificationListenerState
    extends State<GlobalNotificationListener> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _offsetAnimation;
  AppNotification? _currentNotification;
  DateTime? _lastShown;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(0, -2),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutBack,
    ));

    effect(() {
      final notif = appNotificationSignal.value;
      if (notif == null) return;
      if (_lastShown != null && notif.timestamp.isBefore(_lastShown!)) return;

      _lastShown = notif.timestamp;
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showNotification(notif);
      });
    });
  }

  void _showNotification(AppNotification notif) async {
    if (_controller.isAnimating) return;
    
    setState(() {
      _currentNotification = notif;
    });

    await _controller.forward();
    await Future.delayed(const Duration(seconds: 4));
    
    if (mounted) {
      await _controller.reverse();
      setState(() {
        _currentNotification = null;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_currentNotification != null)
          Positioned(
            top: 40,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _offsetAnimation,
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: _currentNotification!.isError 
                        ? Colors.redAccent.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(100),
                      border: Border.all(color: Colors.white10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _currentNotification!.isError 
                            ? Icons.error_outline_rounded 
                            : Icons.check_circle_outline_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _currentNotification!.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
