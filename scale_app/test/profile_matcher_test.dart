import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/models.dart';
import 'package:scale_app/profile_matcher.dart';

Profile _p(String name, double weight) => Profile(
  id: name, name: name, expectedWeight: weight,
  height: 170, birthDate: DateTime.utc(1990, 1, 1), sex: 'male',
);

void main() {
  group('matchProfile', () {
    test('returns null when no profiles', () {
      expect(matchProfile(75, []), isNull);
    });

    test('matches the only profile if within tolerance', () {
      final p = _p('Fabio', 75);
      expect(matchProfile(76, [p]), same(p));
    });

    test('returns null when the only profile is out of tolerance', () {
      final p = _p('Fabio', 75);
      expect(matchProfile(85, [p]), isNull);
    });

    test('picks the closest profile when multiple are within tolerance', () {
      final a = _p('Fabio', 75);
      final b = _p('Wife',  73);
      // weight 74 → 1.0 from b, 1.0 from a → tie, return null
      // weight 73.5 → 0.5 from b, 1.5 from a → b
      expect(matchProfile(73.5, [a, b]), same(b));
    });

    test('returns null on equidistant tie', () {
      final a = _p('Fabio', 75);
      final b = _p('Wife',  73);
      // weight 74 is equidistant
      expect(matchProfile(74, [a, b]), isNull);
    });

    test('returns null when all profiles are out of tolerance', () {
      final a = _p('Fabio', 75);
      final b = _p('Wife',  60);
      expect(matchProfile(50, [a, b]), isNull);
      expect(matchProfile(90, [a, b]), isNull);
      expect(matchProfile(67, [a, b]), isNull);  // 7 from b, 8 from a
    });

    test('±3kg default tolerance: 72 matches a 75kg profile', () {
      expect(matchProfile(72, [_p('Fabio', 75)]), isNotNull);
      expect(matchProfile(78, [_p('Fabio', 75)]), isNotNull);
      expect(matchProfile(71.9, [_p('Fabio', 75)]), isNull);
    });

    test('custom tolerance is respected', () {
      expect(matchProfile(70, [_p('Fabio', 75)], tolerance: 6), isNotNull);
      expect(matchProfile(70, [_p('Fabio', 75)], tolerance: 4), isNull);
    });
  });
}
