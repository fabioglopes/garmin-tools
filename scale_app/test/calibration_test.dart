import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/calibration.dart';
import 'package:scale_app/models.dart';

Measurement _m({
  required String id,
  double? fatPct,
  double? muscleKg,
  double? waterPct,
  double? refFatPct,
  double? refMuscleKg,
  double? refWaterPct,
}) => Measurement(
  id: id, profileId: 'p1',
  timestamp: DateTime.utc(2024, 1, 1),
  weight: 75, unit: 'kg',
  fatPct: fatPct, muscleKg: muscleKg, waterPct: waterPct,
  refFatPct: refFatPct, refMuscleKg: refMuscleKg, refWaterPct: refWaterPct,
);

void main() {
  group('computeCalibration', () {
    test('no reference measurements — returns all null', () {
      final m   = _m(id: 'a', fatPct: 17.0, muscleKg: 52.0, waterPct: 54.0);
      final cal = computeCalibration(m, [m]);
      expect(cal.fatPct,   isNull);
      expect(cal.muscleKg, isNull);
      expect(cal.waterPct, isNull);
      expect(cal.hasAny,   isFalse);
    });

    test('measurement has its own reference — uses it directly', () {
      final m = _m(id: 'a', fatPct: 17.0, muscleKg: 52.0, waterPct: 54.0,
          refFatPct: 22.0, refMuscleKg: 59.0, refWaterPct: 57.0);
      final cal = computeCalibration(m, [m]);
      expect(cal.fatPct,   22.0);
      expect(cal.muscleKg, 59.0);
      expect(cal.waterPct, 57.0);
    });

    test('1 reference point — additive offset', () {
      final ref = _m(id: 'ref', fatPct: 17.0, muscleKg: 52.0, waterPct: 54.0,
          refFatPct: 22.0, refMuscleKg: 59.0, refWaterPct: 57.0);
      final m   = _m(id: 'new', fatPct: 16.0, muscleKg: 53.0, waterPct: 55.0);
      final cal = computeCalibration(m, [ref, m]);
      // offset = 22-17 = +5; corrected = 16+5 = 21
      expect(cal.fatPct,   21.0);
      // offset = 59-52 = +7; corrected = 53+7 = 60
      expect(cal.muscleKg, 60.0);
      // offset = 57-54 = +3; corrected = 55+3 = 58
      expect(cal.waterPct, 58.0);
    });

    test('2 reference points — mean offset', () {
      final r1 = _m(id: 'r1', fatPct: 17.0, refFatPct: 22.0);
      final r2 = _m(id: 'r2', fatPct: 19.0, refFatPct: 23.0);
      final m  = _m(id: 'new', fatPct: 18.0);
      final cal = computeCalibration(m, [r1, r2, m]);
      // offsets: +5, +4 → mean = +4.5; corrected = 18+4.5 = 22.5
      expect(cal.fatPct, 22.5);
    });

    test('3+ reference points — linear regression', () {
      // Perfect linear relationship: corrected = raw + 5 (slope=1, intercept=5)
      final refs = [
        _m(id: 'r1', fatPct: 15.0, refFatPct: 20.0),
        _m(id: 'r2', fatPct: 17.0, refFatPct: 22.0),
        _m(id: 'r3', fatPct: 19.0, refFatPct: 24.0),
      ];
      final m   = _m(id: 'new', fatPct: 16.0);
      final cal = computeCalibration(m, [...refs, m]);
      expect(cal.fatPct, 21.0);
    });

    test('measurement itself is excluded from the model', () {
      // If m's raw values were included in the regression it would corrupt it.
      final r1  = _m(id: 'r1', fatPct: 15.0, refFatPct: 20.0);
      final r2  = _m(id: 'r2', fatPct: 17.0, refFatPct: 22.0);
      final r3  = _m(id: 'r3', fatPct: 19.0, refFatPct: 24.0);
      // m has ref values too — those should be used directly, not fed back into model
      final m   = _m(id: 'new', fatPct: 16.0, refFatPct: 99.0);
      final cal = computeCalibration(m, [r1, r2, r3, m]);
      expect(cal.fatPct, 99.0); // own reference wins
    });

    test('no raw body comp — returns null even with references', () {
      final ref = _m(id: 'ref', fatPct: 17.0, refFatPct: 22.0);
      final m   = _m(id: 'new'); // no fatPct
      final cal = computeCalibration(m, [ref, m]);
      expect(cal.fatPct, isNull);
    });
  });
}
