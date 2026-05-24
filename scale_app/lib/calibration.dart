// Pure-logic calibration for body composition corrections.
// No Flutter/platform imports — fully unit-testable.

import 'models.dart';

class CalibratedValues {
  final double? fatPct;
  final double? muscleKg;
  final double? waterPct;
  const CalibratedValues({this.fatPct, this.muscleKg, this.waterPct});

  bool get hasAny => fatPct != null || muscleKg != null || waterPct != null;
}

/// Compute corrected body composition for [m] using reference-tagged
/// measurements in [allForProfile].
///
/// If [m] itself has manually entered reference values, those are used
/// directly (they are the ground truth). Otherwise the model is built from
/// all OTHER reference-tagged measurements:
///   • <3 reference pairs → mean additive offset
///   • ≥3 reference pairs → ordinary least-squares linear fit (y = a·x + b)
CalibratedValues computeCalibration(
  Measurement m,
  List<Measurement> allForProfile,
) {
  // If the user already entered reference values for this measurement,
  // those ARE the corrected values.
  if (m.refFatPct != null || m.refMuscleKg != null || m.refWaterPct != null) {
    // For metrics without a reference, fall through to the model.
    final refs = allForProfile.where((r) => r.id != m.id).toList();
    return CalibratedValues(
      fatPct:   m.refFatPct   ?? _predict(_fatPairs(refs),    m.fatPct),
      muscleKg: m.refMuscleKg ?? _predict(_musclePairs(refs), m.muscleKg),
      waterPct: m.refWaterPct ?? _predict(_waterPairs(refs),  m.waterPct),
    );
  }

  final refs = allForProfile.where((r) => r.id != m.id).toList();
  return CalibratedValues(
    fatPct:   _predict(_fatPairs(refs),    m.fatPct),
    muscleKg: _predict(_musclePairs(refs), m.muscleKg),
    waterPct: _predict(_waterPairs(refs),  m.waterPct),
  );
}

List<(double, double)> _fatPairs(List<Measurement> refs) => refs
    .where((r) => r.fatPct != null && r.refFatPct != null)
    .map((r) => (r.fatPct!, r.refFatPct!))
    .toList();

List<(double, double)> _musclePairs(List<Measurement> refs) => refs
    .where((r) => r.muscleKg != null && r.refMuscleKg != null)
    .map((r) => (r.muscleKg!, r.refMuscleKg!))
    .toList();

List<(double, double)> _waterPairs(List<Measurement> refs) => refs
    .where((r) => r.waterPct != null && r.refWaterPct != null)
    .map((r) => (r.waterPct!, r.refWaterPct!))
    .toList();

/// Apply calibration model to [rawValue].
/// Returns null if [rawValue] is null or there are no reference pairs.
double? _predict(List<(double, double)> pairs, double? rawValue) {
  if (rawValue == null || pairs.isEmpty) return null;
  if (pairs.length < 3) return _offsetPredict(pairs, rawValue);
  return _linearPredict(pairs, rawValue);
}

double _offsetPredict(List<(double, double)> pairs, double raw) {
  final offset = pairs.map((p) => p.$2 - p.$1).reduce((a, b) => a + b) / pairs.length;
  return double.parse((raw + offset).toStringAsFixed(1));
}

double _linearPredict(List<(double, double)> pairs, double raw) {
  final n    = pairs.length.toDouble();
  final sumX  = pairs.map((p) => p.$1).reduce((a, b) => a + b);
  final sumY  = pairs.map((p) => p.$2).reduce((a, b) => a + b);
  final sumXY = pairs.map((p) => p.$1 * p.$2).reduce((a, b) => a + b);
  final sumX2 = pairs.map((p) => p.$1 * p.$1).reduce((a, b) => a + b);
  final denom = n * sumX2 - sumX * sumX;
  if (denom == 0) return _offsetPredict(pairs, raw); // degenerate: all same raw value
  final a = (n * sumXY - sumX * sumY) / denom;
  final b = (sumY - a * sumX) / n;
  return double.parse((a * raw + b).toStringAsFixed(1));
}
