import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/scale_parser.dart';

void main() {
  group('parseScale', () {
    test('returns null for short payload', () {
      expect(parseScale([0, 1, 2, 3]), isNull);
    });

    test('parses stabilized kg measurement with impedance', () {
      // ctrl1 = 0x22 (stable + has_impedance, kg unit)
      // date 2024-05-22 14:30:45, impedance 500, raw_weight 15000 (= 75.0 kg)
      final bytes = [
        0x00, 0x22,
        0xE8, 0x07,   // year 2024 (little-endian)
        5, 22, 14, 30, 45,
        0xF4, 0x01,   // impedance 500
        0x98, 0x3A,   // raw_weight 15000 → 75.0 kg
      ];
      final r = parseScale(bytes)!;
      expect(r['weight'],        75.0);
      expect(r['unit'],          'kg');
      expect(r['impedance'],     500);
      expect(r['stabilized'],    isTrue);
      expect(r['has_impedance'], isTrue);
      expect(r['scale_ts'],      '2024-5-22-14-30-45');
    });

    test('non-stabilized reading reports stabilized=false', () {
      // ctrl1 = 0x02 (has_impedance only, not stable)
      final bytes = [
        0x00, 0x02,
        0xE8, 0x07, 1, 1, 0, 0, 0,
        0x00, 0x00,
        0x98, 0x3A,
      ];
      expect(parseScale(bytes)!['stabilized'], isFalse);
    });

    test('no-impedance reading nulls impedance field', () {
      // ctrl1 = 0x20 (stable, no impedance)
      final bytes = [
        0x00, 0x20,
        0xE8, 0x07, 1, 1, 0, 0, 0,
        0xFF, 0xFF,   // bytes present but flag says no impedance
        0x98, 0x3A,
      ];
      final r = parseScale(bytes)!;
      expect(r['has_impedance'], isFalse);
      expect(r['impedance'],     isNull);
    });

    test('lbs unit divides raw weight by 100', () {
      // ctrl1 = 0x21 (stable + lbs bit)
      // raw_weight 16500 → 165.0 lbs
      final bytes = [
        0x00, 0x21,
        0xE8, 0x07, 1, 1, 0, 0, 0,
        0x00, 0x00,
        0x74, 0x40,   // 16500
      ];
      final r = parseScale(bytes)!;
      expect(r['weight'], 165.0);
      expect(r['unit'],   'lbs');
    });

    test('jin unit divides raw weight by 100', () {
      // ctrl1 = 0x30 (stable + jin bit)
      final bytes = [
        0x00, 0x30,
        0xE8, 0x07, 1, 1, 0, 0, 0,
        0x00, 0x00,
        0x98, 0x3A,   // 15000 → 150.0 jin
      ];
      final r = parseScale(bytes)!;
      expect(r['weight'], 150.0);
      expect(r['unit'],   'jin');
    });
  });
}
