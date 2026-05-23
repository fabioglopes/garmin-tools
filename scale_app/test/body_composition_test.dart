import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/body_composition.dart';

void main() {
  group('bodyComposition', () {
    // Expected values computed by tracing the formula by hand:
    //
    //   h = 1.73
    //   lbm_base = (173 * 9.058 / 100) * 1.73 + 75 * 0.32 + 12.226
    //            = 15.67034 * 1.73 + 24 + 12.226 = 63.336
    //   lbm = 63.336 - (500 * 0.0068 + 44 * 0.0542)
    //       = 63.336 - 5.7848 = 57.551
    //   coeff = 0.9 (age 44 > 30 and <= 45)
    //   fat_pct = (1 - ((57.551 - 0.8 + 57.551 * 0.9 * 0.05) / 75)) * 100
    //           = (1 - 59.341 / 75) * 100 = 20.88 → 20.9
    //   muscle_kg = 75 - (75 * 20.879 / 100) = 59.34 → 59.3
    //   water_pct = (59.341 / 75) * 73.0 = 57.76 → 57.8
    //   bmi = 75 / 1.73² = 25.06 → 25.1
    test('male age 44 — known input matches hand-computed output', () {
      final r = bodyComposition(
        weight: 75, impedance: 500, height: 173, age: 44, sex: 'male',
      );
      expect(r['fat_pct'],   closeTo(20.9, 0.1));
      expect(r['muscle_kg'], closeTo(59.3, 0.1));
      expect(r['water_pct'], closeTo(57.8, 0.1));
      expect(r['bmi'],       closeTo(25.1, 0.1));
    });

    test('female uses coeff=1.0 path (no age adjustment)', () {
      final r = bodyComposition(
        weight: 60, impedance: 500, height: 165, age: 35, sex: 'female',
      );
      // Sanity: fat should be in human range, muscle < weight
      expect(r['fat_pct'],   greaterThan(10));
      expect(r['fat_pct'],   lessThan(60));
      expect(r['muscle_kg'], lessThan(60));
      expect(r['bmi'],       closeTo(22.0, 0.1));   // 60 / 1.65²
    });

    test('age <= 30 male uses 0.9462 coeff', () {
      final r25 = bodyComposition(
        weight: 75, impedance: 500, height: 173, age: 25, sex: 'male',
      );
      final r46 = bodyComposition(
        weight: 75, impedance: 500, height: 173, age: 46, sex: 'male',
      );
      // Younger coefficient produces different fat estimate than older
      expect(r25['fat_pct'], isNot(equals(r46['fat_pct'])));
    });

    test('fat_pct clamps to floor (5% male, 10% female)', () {
      // Implausibly low impedance forces a negative raw fat → should clamp
      final male = bodyComposition(
        weight: 50, impedance: 100, height: 200, age: 20, sex: 'male',
      );
      expect(male['fat_pct'], greaterThanOrEqualTo(5.0));

      final female = bodyComposition(
        weight: 50, impedance: 100, height: 200, age: 20, sex: 'female',
      );
      expect(female['fat_pct'], greaterThanOrEqualTo(10.0));
    });

    test('values are rounded to 1 decimal place', () {
      final r = bodyComposition(
        weight: 75, impedance: 500, height: 173, age: 44, sex: 'male',
      );
      for (final v in r.values) {
        // No more than 1 decimal of precision
        expect(v * 10, closeTo((v * 10).round(), 0.001));
      }
    });
  });
}
