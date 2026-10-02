// LingoFuseStatus tests. No framework state required.

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

void main() {
  group('LingoFuseStatus', () {
    test('getStatusCount returns a non-negative integer', () {
      expect(LingoFuseStatus.getStatusCount(), greaterThanOrEqualTo(0));
    });

    test('getStatus returns a String', () {
      expect(LingoFuseStatus.getStatus(), isA<String>());
    });

    test('drainStatus with max=0 returns empty without touching the queue',
        () {
      final result = LingoFuseStatus.drainStatus(0);
      expect(result, isEmpty);
    });

    test('drainStatus returns a List<String>', () {
      expect(LingoFuseStatus.drainStatus(64), isA<List<String>>());
    });

    test('drainStatus negative max is treated as zero', () {
      final result = LingoFuseStatus.drainStatus(-1);
      expect(result, isEmpty);
    });
  });
}