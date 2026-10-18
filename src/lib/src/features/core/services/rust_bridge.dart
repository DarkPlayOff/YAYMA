import 'dart:async';

import 'package:yayma/src/app/init.dart' as app_init;
import 'package:yayma/src/app/session.dart';
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
    _handleRustError(e, true);
    return false;
  }
}

/// Safely fetches data from Rust.
/// Returns null if there is no context or on error.
/// Set [notifyErrors] to false when the caller aggregates failures
/// itself (e.g. fan-out fetches) to avoid one alert per call.
Future<T?> runRustFetch<T>(
  Future<T> Function(AppContext ctx) fetcher, {
  bool notifyErrors = true,
}) async {
  final ctx = appContextSignal.value;
  if (ctx == null) return null;
  try {
    return await fetcher(ctx);
  } on Object catch (e) {
    _handleRustError(e, notifyErrors);
    return null;
  }
}

void _handleRustError(Object e, bool notifyErrors) {
  final errorStr = e.toString();
  if (errorStr.contains('Invalid token or session expired') ||
      errorStr.contains('Unauthorized')) {
    // Auth failures are always surfaced: the session must be re-established.
    showAppError('Сессия истекла. Пожалуйста, войдите снова.');
    unawaited(app_init.AppInit.logout());
  } else if (notifyErrors) {
    showAppError(errorStr);
  }
}
