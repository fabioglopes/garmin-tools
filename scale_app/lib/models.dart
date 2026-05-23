// Plain-Dart data models for profiles and measurements.
// Kept free of Flutter/platform imports so they can be unit-tested.

/// True if `m` looks like a duplicate of something already in `existing`.
///
/// The Xiaomi scale rebroadcasts the same advertisement repeatedly for several
/// minutes after a weigh-in, and individual packets vary slightly — sometimes
/// the weight drifts by ±0.05 kg, sometimes the impedance flag flips off in
/// follow-up packets. So we treat two measurements as the same weigh-in if
/// they fall within the time window and the weight matches within ±0.15 kg
/// (regardless of impedance). The caller should pass *all* stored
/// measurements, including soft-deleted ones, so that deleting in the UI
/// doesn't cause the next stray broadcast to re-create the record.
bool isDuplicateMeasurement(
  Measurement m,
  List<Measurement> existing, {
  Duration window = const Duration(minutes: 2),
  double weightTolerance = 0.15,
}) {
  final cutoffPast   = m.timestamp.subtract(window);
  final cutoffFuture = m.timestamp.add(window);
  for (final e in existing) {
    if (e.id == m.id) continue;
    if (e.timestamp.isBefore(cutoffPast))   continue;
    if (e.timestamp.isAfter(cutoffFuture))  continue;
    if ((e.weight - m.weight).abs() <= weightTolerance) return true;
  }
  return false;
}

class Profile {
  final String id;
  String name;
  double expectedWeight;   // kg, auto-updated to last measured weight
  double height;            // cm
  DateTime birthDate;       // stored as UTC midnight
  String sex;               // 'male' | 'female'
  String? garminEmail;      // null = app-only profile

  Profile({
    required this.id,
    required this.name,
    required this.expectedWeight,
    required this.height,
    required this.birthDate,
    required this.sex,
    this.garminEmail,
  });

  bool get hasGarmin => garminEmail != null && garminEmail!.isNotEmpty;

  /// Age in completed years on the given date. Use the measurement's timestamp
  /// so historical readings get the correct age, not today's.
  int ageOn(DateTime when) {
    var age = when.year - birthDate.year;
    if (when.month < birthDate.month ||
        (when.month == birthDate.month && when.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  int get age => ageOn(DateTime.now());

  Map<String, dynamic> toJson() => {
    'id':              id,
    'name':            name,
    'expected_weight': expectedWeight,
    'height':          height,
    'birth_date':      birthDate.toUtc().toIso8601String(),
    'sex':             sex,
    'garmin_email':    garminEmail,
  };

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    id:             j['id'] as String,
    name:           j['name'] as String,
    expectedWeight: (j['expected_weight'] as num).toDouble(),
    height:         (j['height'] as num).toDouble(),
    birthDate:      _parseBirthDate(j),
    sex:            j['sex'] as String,
    garminEmail:    j['garmin_email'] as String?,
  );

  /// Read birth date from JSON, falling back to the legacy `age` field
  /// (approximate: Jan 1 of `current_year - age`). Keeps old saved profiles
  /// loadable instead of crashing.
  static DateTime _parseBirthDate(Map<String, dynamic> j) {
    final bd = j['birth_date'] as String?;
    if (bd != null) return DateTime.parse(bd);
    final age = j['age'] as int?;
    if (age != null) {
      return DateTime.utc(DateTime.now().year - age, 1, 1);
    }
    return DateTime.utc(1990, 1, 1);
  }
}

class Measurement {
  final String id;
  String? profileId;        // null = unassigned, awaiting user pick
  final DateTime timestamp;
  final double weight;
  final String unit;
  final int?    impedance;
  final double? fatPct;
  final double? muscleKg;
  final double? waterPct;
  final double? bmi;
  bool      synced;
  DateTime? syncedAt;
  String?   syncError;
  bool      deleted;        // soft delete — hidden in UI but kept for dedup

  Measurement({
    required this.id,
    required this.profileId,
    required this.timestamp,
    required this.weight,
    required this.unit,
    this.impedance,
    this.fatPct,
    this.muscleKg,
    this.waterPct,
    this.bmi,
    this.synced    = false,
    this.syncedAt,
    this.syncError,
    this.deleted   = false,
  });

  Map<String, dynamic> toJson() => {
    'id':         id,
    'profile_id': profileId,
    'timestamp':  timestamp.toUtc().toIso8601String(),
    'weight':     weight,
    'unit':       unit,
    'impedance':  impedance,
    'fat_pct':    fatPct,
    'muscle_kg':  muscleKg,
    'water_pct':  waterPct,
    'bmi':        bmi,
    'synced':     synced,
    'synced_at':  syncedAt?.toUtc().toIso8601String(),
    'sync_error': syncError,
    'deleted':    deleted,
  };

  factory Measurement.fromJson(Map<String, dynamic> j) => Measurement(
    id:         j['id'] as String,
    profileId:  j['profile_id'] as String?,
    timestamp:  DateTime.parse(j['timestamp'] as String),
    weight:     (j['weight'] as num).toDouble(),
    unit:       j['unit'] as String,
    impedance:  j['impedance'] as int?,
    fatPct:     (j['fat_pct']   as num?)?.toDouble(),
    muscleKg:   (j['muscle_kg'] as num?)?.toDouble(),
    waterPct:   (j['water_pct'] as num?)?.toDouble(),
    bmi:        (j['bmi']       as num?)?.toDouble(),
    synced:     j['synced'] as bool? ?? false,
    syncedAt:   j['synced_at'] != null ? DateTime.parse(j['synced_at'] as String) : null,
    syncError:  j['sync_error'] as String?,
    deleted:    j['deleted'] as bool? ?? false,
  );
}
