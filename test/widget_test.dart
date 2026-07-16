import 'package:flutter_test/flutter_test.dart';

import 'package:cobuying/core/formatters.dart';

void main() {
  group('formatRemaining', () {
    test('마감 전에는 남은 시간을 표시한다', () {
      expect(formatRemaining(const Duration(hours: 5, minutes: 3, seconds: 2)),
          '05:03:02');
      expect(
          formatRemaining(const Duration(days: 2, hours: 1)), '2일 01:00:00');
    });

    test('기한이 지나면 마감으로 표시한다', () {
      expect(formatRemaining(const Duration(seconds: -1)), '마감');
    });
  });
}
