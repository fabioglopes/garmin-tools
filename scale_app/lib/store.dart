import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

/// File-backed JSON storage for profiles and measurements.
///
/// Both reads load the whole list into memory; writes serialize the whole
/// list back. Fine for the expected scale of data (~thousands of entries
/// max). Writes go through a temp-file-and-rename for atomicity, since the
/// background isolate and UI isolate can both touch these files.
class Store {
  static const _profilesFile     = 'profiles.json';
  static const _measurementsFile = 'measurements.json';
  static const _secure = FlutterSecureStorage();

  // ── Profiles ─────────────────────────────────────────────────────────────

  static Future<List<Profile>> loadProfiles() async {
    final f = await _file(_profilesFile);
    if (!await f.exists()) return [];
    final raw = await f.readAsString();
    if (raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    final out = <Profile>[];
    for (final j in list) {
      try {
        out.add(Profile.fromJson(j as Map<String, dynamic>));
      } catch (e) {
        // Skip corrupt entries instead of failing the whole load
      }
    }
    return out;
  }

  static Future<void> saveProfiles(List<Profile> profiles) async {
    final f = await _file(_profilesFile);
    await _atomicWrite(f, jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }

  // ── Measurements ─────────────────────────────────────────────────────────

  /// Load measurements. By default returns only active (not soft-deleted)
  /// entries — pass `includeDeleted: true` for dedup or bookkeeping that
  /// needs to see tombstones.
  static Future<List<Measurement>> loadMeasurements({bool includeDeleted = false}) async {
    final f = await _file(_measurementsFile);
    if (!await f.exists()) return [];
    final raw = await f.readAsString();
    if (raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    final all = <Measurement>[];
    for (final j in list) {
      try {
        all.add(Measurement.fromJson(j as Map<String, dynamic>));
      } catch (_) {
        // Skip corrupt entries
      }
    }
    return includeDeleted ? all : all.where((m) => !m.deleted).toList();
  }

  static Future<void> saveMeasurements(List<Measurement> ms) async {
    final f = await _file(_measurementsFile);
    await _atomicWrite(f, jsonEncode(ms.map((m) => m.toJson()).toList()));
  }

  /// Append a single measurement. Loads full list, appends, saves back.
  static Future<void> appendMeasurement(Measurement m) async {
    final all = await loadMeasurements(includeDeleted: true);
    all.add(m);
    await saveMeasurements(all);
  }

  /// Update an existing measurement by id. Silently no-ops if id not found.
  static Future<void> updateMeasurement(Measurement m) async {
    final all = await loadMeasurements(includeDeleted: true);
    final i = all.indexWhere((x) => x.id == m.id);
    if (i == -1) return;
    all[i] = m;
    await saveMeasurements(all);
  }

  /// Soft-delete a measurement by id. The entry stays in storage as a
  /// tombstone so the BLE dedup keeps seeing it — otherwise the scale's
  /// continued rebroadcasts would re-create the record. Silently no-ops if
  /// not found.
  static Future<void> deleteMeasurement(String id) async {
    final all = await loadMeasurements(includeDeleted: true);
    final i = all.indexWhere((m) => m.id == id);
    if (i == -1) return;
    all[i].deleted = true;
    await saveMeasurements(all);
  }

  // ── Per-profile secrets (password + token) ───────────────────────────────

  static String _pwKey(String pid)    => 'profile_${pid}_password';
  static String _tokenKey(String pid) => 'profile_${pid}_token';

  static Future<void> savePassword(String pid, String password) =>
      _secure.write(key: _pwKey(pid), value: password);

  static Future<String?> readPassword(String pid) =>
      _secure.read(key: _pwKey(pid));

  static Future<void> deletePassword(String pid) =>
      _secure.delete(key: _pwKey(pid));

  static Future<void> saveToken(String pid, String token) =>
      _secure.write(key: _tokenKey(pid), value: token);

  static Future<String?> readToken(String pid) =>
      _secure.read(key: _tokenKey(pid));

  static Future<void> deleteToken(String pid) =>
      _secure.delete(key: _tokenKey(pid));

  /// Clear everything for a profile (password + token).
  static Future<void> clearSecrets(String pid) async {
    await deletePassword(pid);
    await deleteToken(pid);
  }

  // ── Internals ────────────────────────────────────────────────────────────

  static Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$name');
  }

  static Future<void> _atomicWrite(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }
}
