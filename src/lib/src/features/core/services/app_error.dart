import 'package:yayma/src/features/core/services/app_logger.dart';
import 'package:yayma/src/rust/api/models.dart';

/// Whether [error] means the session is no longer valid.
///
/// The bridge carries a typed `AppError`, so match the two auth variants
/// instead of scanning messages: a stale stream URL returning 401 used to
/// parse as "unauthorized" and log the user out mid-track.
bool isSessionExpired(Object error) {
  if (error is AppError_Unauthorized || error is AppError_InvalidToken) {
    return true;
  }
  // Fallback for errors that lose their type crossing the bridge (panics,
  // boxed errors): only the exact auth wording counts, not a bare "401".
  final message = error.toString().toLowerCase();
  return message.contains('invalid token or session expired') ||
      message.contains('invalid token');
}

/// Russian text for [error] that is safe to show to the user.
///
/// The Rust layer reports failures with stable English prefixes (see `AppError`
/// in `rust/src/api/models.rs`), so the prefix is the only signal available.
/// Anything unrecognised is logged in full and replaced with a generic line:
/// never show a stack trace or an internal message in the UI.
String humanizeError(Object error) {
  appLog(AppLogLevel.warn, 'handled error: $error');

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
