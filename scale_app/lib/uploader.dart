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

  try {
    await client.uploadBodyComposition(
      timestamp:        m.timestamp,
      weight:           m.weight,
      height:           profile.height,
      percentFat:       m.fatPct,
      percentHydration: m.waterPct,
      muscleKg:         m.muscleKg,
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
