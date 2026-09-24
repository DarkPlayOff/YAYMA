import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/init.dart' as app_init;
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
