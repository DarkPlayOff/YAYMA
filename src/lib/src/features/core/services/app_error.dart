import 'package:material_ui/material_ui.dart';

/// Whether [error] means the session is no longer valid.
///
/// The Rust layer reports auth failures as messages carrying
/// "invalid token" / "unauthorized" (see `AppError` in
/// `rust/src/api/models.rs`); there is no typed error across the bridge yet.
bool isSessionExpired(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('invalid token') ||
      message.contains('unauthorized') ||
      message.contains('session expired');
}

/// Russian text for [error] that is safe to show to the user.
///
/// The Rust layer reports failures with stable English prefixes (see `AppError`
/// in `rust/src/api/models.rs`), so the prefix is the only signal available.
/// Anything unrecognised is logged in full and replaced with a generic line:
/// never show a stack trace or an internal message in the UI.
String humanizeError(Object error) {
  debugPrint('Handled error: $error');

  if (isSessionExpired(error)) return 'Сессия истекла. Войдите снова.';

  final message = error.toString().toLowerCase();
  if (message.contains('network error') ||
      message.contains('connection') ||
      message.contains('timed out') ||
      message.contains('timeout') ||
      message.contains('socket')) {
    return 'Нет подключения к сети. Проверьте интернет-соединение.';
  }
  if (message.contains('rate limited') ||
      message.contains('too many requests')) {
    return 'Слишком много запросов. Попробуйте позже.';
  }
  if (message.contains('not found')) {
    return 'Не найдено. Возможно, оно было удалено.';
  }
  if (message.contains('audio system not initialized')) {
    return 'Аудиосистема недоступна. Перезапустите приложение.';
  }
  if (message.contains('database error')) {
    return 'Ошибка локальной базы данных. Попробуйте очистить кэш в настройках.';
  }
  if (message.contains('io error')) {
    return 'Не удалось обратиться к файлу. Проверьте папку загрузок.';
  }
  if (message.contains('api error')) {
    return 'Сервис вернул ошибку. Попробуйте позже.';
  }
  return 'Не удалось выполнить действие. Попробуйте ещё раз.';
}
