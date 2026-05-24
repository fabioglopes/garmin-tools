import 'calibration.dart';
import 'garmin_client.dart';
import 'models.dart';
import 'store.dart';

/// Upload a measurement to Garmin for the given profile.
///
/// Reads the stored password + last access token, retries with a fresh login
/// on 401, persists the refreshed token, and updates the measurement's
/// `synced` / `syncedAt` / `syncError` fields in storage regardless of
/// outcome. Throws on failure (after recording the error), so the caller can
/// surface it.
Future<void> uploadMeasurement(Profile profile, Measurement m) async {
  if (!profile.hasGarmin) {
    throw Exception('${profile.name} has no Garmin account configured.');
  }
  if (!profile.syncEnabled) {
    throw Exception('${profile.name}: sync is disabled. Enable it in the profile settings.');
  }
  final password = await Store.readPassword(profile.id);
  if (password == null || password.isEmpty) {
    throw Exception('${profile.name}: password not stored. Open profile → Login.');
  }
  final token = await Store.readToken(profile.id);

  final client = GarminClient(
    email: profile.garminEmail!,
    password: password,
    token: token,
    onTokenRefreshed: (t, _) => Store.saveToken(profile.id, t),
  );

  // Resolve which body-comp values to send.
  double? uploadFat    = m.fatPct;
  double? uploadMuscle = m.muscleKg;
  double? uploadWater  = m.waterPct;
  if (profile.correctValues && m.fatPct != null) {
    final all = await Store.loadMeasurements(includeDeleted: false);
    final forProfile = all.where((x) => x.profileId == profile.id).toList();
    final cal = computeCalibration(m, forProfile);
    if (cal.hasAny) {
      uploadFat    = cal.fatPct    ?? uploadFat;
      uploadMuscle = cal.muscleKg  ?? uploadMuscle;
      uploadWater  = cal.waterPct  ?? uploadWater;
    }
  }

  try {
    await client.uploadBodyComposition(
      timestamp:        m.timestamp,
      weight:           m.weight,
      height:           profile.height,
      percentFat:       uploadFat,
      percentHydration: uploadWater,
      muscleKg:         uploadMuscle,
    );
    m.synced    = true;
    m.syncedAt  = DateTime.now();
    m.syncError = null;
    await Store.updateMeasurement(m);
  } catch (e) {
    m.syncError = e.toString();
    await Store.updateMeasurement(m);
    rethrow;
  }
}
