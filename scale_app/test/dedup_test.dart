import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/models.dart';

Measurement _m({
  required String id,
  required DateTime ts,
  required double w,
  int? imp,
  bool deleted = false,
  DateTime? deletedAt,
}) => Measurement(
  id: id, profileId: null, timestamp: ts, weight: w, unit: 'kg',
  impedance: imp, deleted: deleted, deletedAt: deletedAt,
);

void main() {
  group('isDuplicateMeasurement', () {
    test('empty list — never duplicate', () {
      final m = _m(id: 'a', ts: DateTime.utc(2024,1,1,10), w: 75, imp: 500);
      expect(isDuplicateMeasurement(m, []), isFalse);
    });

    test('same weight within 2 min — duplicate', () {
      final base = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0),  w: 75.0, imp: 500);
      final near = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.0, imp: 500);
      expect(isDuplicateMeasurement(near, [base]), isTrue);
    });

    test('same weight ±0.1 kg counts as same (within tolerance)', () {
      final base = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0),  w: 75.00, imp: 500);
      final a    = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.10, imp: 500);
      final b    = _m(id: '3', ts: DateTime.utc(2024,1,1,10,0,45), w: 74.90, imp: 500);
      expect(isDuplicateMeasurement(a, [base]), isTrue);
      expect(isDuplicateMeasurement(b, [base]), isTrue);
    });

    test('weight differs by 0.3 kg — not a duplicate', () {
      final base = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0),  w: 75.0, imp: 500);
      final far  = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.3, imp: 500);
      expect(isDuplicateMeasurement(far, [base]), isFalse);
    });

    test('same weight even if impedance flag flipped off — duplicate', () {
      // The scale sometimes broadcasts a follow-up packet with the same weight
      // but no impedance. Without impedance-agnostic dedup, that creates a
      // second record. Locked down here as a regression test.
      final base = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0),  w: 75.0, imp: 500);
      final near = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.0, imp: null);
      expect(isDuplicateMeasurement(near, [base]), isTrue);
    });

    test('outside 2-min window — not a duplicate', () {
      final base = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0), w: 75.0, imp: 500);
      final far  = _m(id: '2', ts: DateTime.utc(2024,1,1,10,3,0), w: 75.0, imp: 500);
      expect(isDuplicateMeasurement(far, [base]), isFalse);
    });

    test('same id is not its own duplicate (used for replays/updates)', () {
      final m = _m(id: 'self', ts: DateTime.utc(2024,1,1,10), w: 75, imp: 500);
      expect(isDuplicateMeasurement(m, [m]), isFalse);
    });

    test('soft-deleted measurement still suppresses BLE rebroadcasts', () {
      // The whole point of soft delete: dedup must keep seeing tombstones,
      // otherwise the scale's continued rebroadcasts re-create the entry.
      final deletedAt = DateTime.utc(2024,1,1,10,1,0);
      final tombstone = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0), w: 75.0, imp: 500,
          deleted: true, deletedAt: deletedAt);
      // Replay arrives 30 s after original measurement but BEFORE deletion → still blocked.
      final replay = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.0, imp: 500);
      expect(isDuplicateMeasurement(replay, [tombstone]), isTrue);
    });

    test('tombstone does not block re-weigh that happens after the deletion', () {
      // User deleted a weight-only measurement, then the person steps on the
      // scale again. The new measurement's timestamp is after deletedAt, so
      // the tombstone must be ignored.
      final deletedAt = DateTime.utc(2024,1,1,10,1,0);
      final tombstone = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0), w: 75.0, imp: 500,
          deleted: true, deletedAt: deletedAt);
      // New attempt: same weight, arrives AFTER the user deleted.
      final reWeigh = _m(id: '3', ts: DateTime.utc(2024,1,1,10,1,30), w: 75.0, imp: 500);
      expect(isDuplicateMeasurement(reWeigh, [tombstone]), isFalse);
    });

    test('tombstone without deletedAt (legacy) still suppresses within window', () {
      // Old tombstones stored before deletedAt was introduced have null deletedAt.
      // They fall back to the original time-window dedup behavior.
      final tombstone = _m(id: '1', ts: DateTime.utc(2024,1,1,10,0,0), w: 75.0, imp: 500,
          deleted: true);
      final replay = _m(id: '2', ts: DateTime.utc(2024,1,1,10,0,30), w: 75.0, imp: 500);
      expect(isDuplicateMeasurement(replay, [tombstone]), isTrue);
    });
  });
}
