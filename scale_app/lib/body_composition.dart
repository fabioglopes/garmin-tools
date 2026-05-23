/// Body composition estimate from weight + bioelectrical impedance.
///
/// Port of the Xiaomi Mi Scale formula. Inputs:
///   weight    kg
///   impedance ohms (from the scale's BIA electrodes)
///   height    cm
///   age       years
///   sex       'male' | 'female'
///
/// Returned values are rounded to 1 decimal place.
Map<String, double> bodyComposition({
  required double weight,
  required int impedance,
  required double height,
  required int age,
  required String sex,
}) {
  final h = height / 100;
  double lbm = (height * 9.058 / 100) * h + weight * 0.32 + 12.226;
  lbm -= impedance * 0.0068 + age * 0.0542;

  double fatPct;
  if (sex == 'male') {
    final coeff = age <= 30 ? 0.9462 : (age <= 45 ? 0.9 : 1.0);
    fatPct = (1 - ((lbm - 0.8 + lbm * coeff * 0.05) / weight)) * 100;
    fatPct = fatPct.clamp(5.0, 75.0);
  } else {
    fatPct = (1 - ((lbm - 0.8 + lbm * 0.05) / weight)) * 100;
    fatPct = fatPct.clamp(10.0, 75.0);
  }

  final muscleKg = weight - (weight * fatPct / 100);
  final waterPct = (muscleKg / weight) * 73.0;
  final bmi      = weight / (h * h);

  return {
    'fat_pct':   double.parse(fatPct.toStringAsFixed(1)),
    'muscle_kg': double.parse(muscleKg.toStringAsFixed(1)),
    'water_pct': double.parse(waterPct.toStringAsFixed(1)),
    'bmi':       double.parse(bmi.toStringAsFixed(1)),
  };
}
