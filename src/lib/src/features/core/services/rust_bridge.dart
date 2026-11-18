import 'dart:async';

import 'package:yayma/src/app/init.dart' as app_init;
import 'package:yayma/src/app/session.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/core/services/app_error.dart';
import 'package:yayma/src/features/core/services/app_logger.dart';
import 'package:yayma/src/rust/api/auth.dart' as rust;
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
    await _handleRustError(e, ctx, true);
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
    await _handleRustError(e, ctx, notifyErrors);
    return null;
  }
}

/// Logs out only when the session is *confirmed* dead: probes the account
/// status once, mirroring the official desktop client's "confirmed-401"
/// check. A single 401 can be transient or come from a stale URL, so the
/// session is kept when the probe succeeds or cannot decide.
Future<void> confirmedLogout(AppContext ctx, Object error) async {
  // A request that started before the last login/logout must not tear down
  // the session that replaced it.
  if (!identical(appContextSignal.value, ctx)) return;
  try {
    if (await rust.verifyAuth(ctx: ctx)) return;
  } on Object {
    // Probe failed to run: fall through and log out, as before.
  }
  showAppError(humanizeError(error));
  unawaited(app_init.AppInit.logout());
}

Future<void> _handleRustError(Object e, AppContext ctx, bool notifyErrors) async {
  // Every Rust failure lands in the file log, even when it is not surfaced
  // to the user.
  appLog(AppLogLevel.error, 'rust action failed: $e');
  if (isSessionExpired(e)) {
    await confirmedLogout(ctx, e);
  } else if (notifyErrors) {
    showAppError(humanizeError(e));
  }
}
