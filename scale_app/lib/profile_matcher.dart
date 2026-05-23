import 'models.dart';

/// Match a weight reading to the most likely profile.
///
/// Returns the profile whose `expectedWeight` is closest to `weight` within
/// the tolerance window. Returns null if the closest is still outside the
/// tolerance, or if there are no profiles.
///
/// When two profiles are equidistant (a tie within tolerance), returns null —
/// the user should disambiguate explicitly rather than the code guessing.
Profile? matchProfile(double weight, List<Profile> profiles, {double tolerance = 3.0}) {
  if (profiles.isEmpty) return null;

  Profile? best;
  double bestDiff = double.infinity;
  bool   tied     = false;

  for (final p in profiles) {
    final diff = (p.expectedWeight - weight).abs();
    if (diff > tolerance) continue;
    if (diff < bestDiff) {
      best = p;
      bestDiff = diff;
      tied = false;
    } else if (diff == bestDiff) {
      tied = true;
    }
  }

  return tied ? null : best;
}
