import 'dart:async';

import 'package:yayma/src/app/init.dart' as app_init;
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/rust/app/context.dart';

/// Executes a Rust action safely, catches errors and shows a notification.
/// Returns true on success or if the action returned true, otherwise false.
Future<bool> runRustAction(
  Future<dynamic> Function(AppContext ctx) action,
) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return false;
  try {
    final result = await action(ctx);
    if (result is bool) return result;
    return true;
  } on Object catch (e) {
    _handleRustError(e);
    return false;
  }
}

/// Safely fetches data from Rust.
/// Returns null if there is no context or on error.
Future<T?> runRustFetch<T>(Future<T> Function(AppContext ctx) fetcher) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return null;
  try {
    return await fetcher(ctx);
  } on Object catch (e) {
    _handleRustError(e);
    return null;
  }
}

void _handleRustError(Object e) {
  final errorStr = e.toString();
  if (errorStr.contains('Invalid token or session expired') ||
      errorStr.contains('Unauthorized')) {
    showAppError('Сессия истекла. Пожалуйста, войдите снова.');
    unawaited(app_init.AppInit.logout());
  } else {
    showAppError(errorStr);
  }
}
