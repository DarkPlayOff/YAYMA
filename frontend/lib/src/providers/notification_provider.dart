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
    extends State<GlobalNotificationListener> {
  EffectCleanup? _cleanup;

  @override
  void initState() {
    super.initState();
    _cleanup = effect(() {
      final notif = appNotificationSignal.value;
      if (notif == null) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(notif.message),
            backgroundColor: notif.isError
                ? Colors.red.shade800
                : Colors.green.shade800,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            margin: const EdgeInsets.only(bottom: 120, left: 100, right: 100),
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _cleanup?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
