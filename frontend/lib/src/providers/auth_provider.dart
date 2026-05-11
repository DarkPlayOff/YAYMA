import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/init.dart' as app_init;
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/app/context.dart';

// State signals
final FlutterSignal<AsyncState<bool>> authSignal = signal<AsyncState<bool>>(
  const AsyncLoading(),
);
final FlutterSignal<UserAccountDto?> accountSignal = signal<UserAccountDto?>(
  null,
);
final FlutterSignal<AppContext?> appContextSignal = signal<AppContext?>(null);

// Redefinition of initialization functions for backward compatibility
// Real logic is now in AppInit
Future<void> initAuth() => app_init.AppInit.initialize();

// Export login/logout for UI
Future<void> login(String token) => app_init.AppInit.login(token);
Future<void> logout() => app_init.AppInit.logout();

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
    showAppError(e.toString());
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
    showAppError(e.toString());
    return null;
  }
}
