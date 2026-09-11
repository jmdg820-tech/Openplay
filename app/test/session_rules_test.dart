import 'package:flutter_test/flutter_test.dart';
import 'package:openplay_app/utils/session_rules.dart';

void main() {
  group('minCapacityFor', () {
    test('singles minimum is 2', () => expect(minCapacityFor('singles'), 2));
    test('doubles minimum is 4', () => expect(minCapacityFor('doubles'), 4));
  });

  group('validateCapacity', () {
    test('rejects null capacity', () {
      expect(validateCapacity('doubles', null), isNotNull);
    });

    test('rejects below-minimum capacity for singles', () {
      expect(validateCapacity('singles', 1), isNotNull);
    });

    test('rejects below-minimum capacity for doubles', () {
      expect(validateCapacity('doubles', 3), isNotNull);
    });

    test('accepts exactly the minimum', () {
      expect(validateCapacity('singles', 2), isNull);
      expect(validateCapacity('doubles', 4), isNull);
    });

    test('accepts a capacity that is NOT a multiple of the game size', () {
      // Explicit approved-architecture requirement: capacity does not have
      // to be a multiple of the game size.
      expect(validateCapacity('doubles', 5), isNull);
      expect(validateCapacity('doubles', 7), isNull);
      expect(validateCapacity('singles', 3), isNull);
    });
  });
}
