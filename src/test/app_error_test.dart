import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/core/services/app_error.dart';
import 'package:yayma/src/features/core/utils/track_ids.dart';

void main() {
  group('humanizeError', () {
    test('flags a dead session and collapses it to one message', () {
      const error = 'Invalid token or session expired';
      expect(isSessionExpired(error), isTrue);
      expect(humanizeError(error), 'Сессия истекла. Войдите снова.');
    });

    test('does not log out on an unrelated failure', () {
      expect(isSessionExpired('Resource not found: 42'), isFalse);
    });

    test('maps the Rust error prefixes', () {
      expect(
        humanizeError('Network error: please check your connection'),
        contains('сети'),
      );
      expect(
        humanizeError('Resource not found: track 42'),
        contains('Не найдено'),
      );
      expect(
        humanizeError('Rate limited: too many requests'),
        contains('Слишком много'),
      );
      expect(humanizeError('IO error: access denied'), contains('файлу'));
    });

    test('never leaks an unrecognised message to the screen', () {
      const raw = 'Unknown error: thread panicked at src/audio/queue.rs:88';
      expect(humanizeError(raw), isNot(contains('queue.rs')));
      expect(
        humanizeError(raw),
        'Не удалось выполнить действие. Попробуйте ещё раз.',
      );
    });
  });

  test('baseTrackId strips the album suffix', () {
    expect(baseTrackId('123:456'), '123');
    expect(baseTrackId('123'), '123');
  });
}
