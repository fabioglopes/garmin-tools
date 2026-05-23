import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/fit_encoder.dart';

void main() {
  group('FitEncoder', () {
    FitEncoder buildSample() {
      final dt = DateTime.utc(2024, 1, 1);
      return FitEncoder()
        ..writeFileId(dt)
        ..writeFileCreator()
        ..writeDeviceInfo(dt)
        ..writeWeightScale(
          dt: dt,
          weight: 75.0,
          percentFat: 20.0,
          percentHydration: 55.0,
          muscleKg: 60.0,
          bmi: 25.1,
        );
    }

    test('output starts with valid 14-byte FIT header', () {
      final bytes = buildSample().encode();
      expect(bytes.length, greaterThan(16));      // header (14) + body + 2 CRC
      expect(bytes[0], 14);                        // header size
      expect(bytes[1], 0x20);                      // protocol version 2.0
      // '.FIT' magic at bytes 8..11
      expect(bytes.sublist(8, 12), [0x2E, 0x46, 0x49, 0x54]);
    });

    test('header advertises body length matching actual body length', () {
      final bytes = buildSample().encode();
      // bytes 4..8 = uint32 LE body length
      final bodyLen = bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24);
      // Total = 14 header (CRC already included) + body + 2 body CRC
      expect(bytes.length, 14 + bodyLen + 2);
    });

    test('encoding is deterministic for the same input', () {
      expect(buildSample().encode(), buildSample().encode());
    });

    test('different weight produces different output', () {
      final dt = DateTime.utc(2024, 1, 1);
      final a = (FitEncoder()
            ..writeFileId(dt)
            ..writeFileCreator()
            ..writeDeviceInfo(dt)
            ..writeWeightScale(dt: dt, weight: 75.0))
          .encode();
      final b = (FitEncoder()
            ..writeFileId(dt)
            ..writeFileCreator()
            ..writeDeviceInfo(dt)
            ..writeWeightScale(dt: dt, weight: 76.0))
          .encode();
      expect(a, isNot(equals(b)));
    });

    test('null optional fields encode as FIT invalid sentinel (0xFFFF)', () {
      final dt = DateTime.utc(2024, 1, 1);
      // Build with only weight; fat/hydration/muscle/bone/bmi omitted
      final bytes = (FitEncoder()
            ..writeFileId(dt)
            ..writeFileCreator()
            ..writeDeviceInfo(dt)
            ..writeWeightScale(dt: dt, weight: 75.0))
          .encode();
      // The weight-scale record (local msg 3) has 4-byte timestamp + six uint16
      // fields. Missing optional fields should be 0xFFFF somewhere in body.
      final body = bytes.sublist(14, bytes.length - 2);
      // Find a 0xFF 0xFF pair (FIT invalid uint16) — must be present given
      // we omitted multiple optional fields
      var foundInvalid = false;
      for (var i = 0; i < body.length - 1; i++) {
        if (body[i] == 0xFF && body[i + 1] == 0xFF) {
          foundInvalid = true;
          break;
        }
      }
      expect(foundInvalid, isTrue);
    });
  });
}
