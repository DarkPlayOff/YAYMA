import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/app/init.dart' as app_init;
import 'package:yayma/src/providers/notification_provider.dart';
import 'package:yayma/src/rust/api/models.dart';
import 'package:yayma/src/rust/app/context.dart';

// Сигналы состояния
final FlutterSignal<AsyncState<bool>> authSignal = signal<AsyncState<bool>>(
  const AsyncLoading(),
);
final FlutterSignal<UserAccountDto?> accountSignal = signal<UserAccountDto?>(
  null,
);
final FlutterSignal<AppContext?> appContextSignal = signal<AppContext?>(null);

// Переопределение функций инициализации для обратной совместимости
// Реальная логика теперь в AppInit
Future<void> initAuth() => app_init.AppInit.initialize();

// Экспорт login/logout для UI
Future<void> login(String token) => app_init.AppInit.login(token);
Future<void> logout() => app_init.AppInit.logout();

/// Выполняет действие Rust безопасно, ловит ошибки и показывает уведомление.
/// Возвращает true при успехе или если действие вернуло true, иначе false.
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

/// Выполняет получение данных из Rust безопасно.
/// Возвращает null при отсутствии контекста или ошибке.
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
