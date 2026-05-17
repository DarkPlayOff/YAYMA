import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';

void main() {
  test('a', () {
    print(MediaControl.custom(androidIcon: 'ic', label: 'L', name: 'N'));
  });
}