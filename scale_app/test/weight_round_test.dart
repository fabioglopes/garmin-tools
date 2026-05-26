import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/models.dart';

void main() {
  group('floorToTenthKg', () {
    test('floors a half-tenth reading down (75.05 -> 75.0)', () {
      expect(floorToTenthKg(75.05), 75.0);
    });

    test('leaves an exact tenth untouched (75.1 -> 75.1)', () {
      expect(floorToTenthKg(75.1), 75.1);
    });

    test('floors values just below the next tenth (75.155 -> 75.1)', () {
      expect(floorToTenthKg(75.155), 75.1);
    });

    test('whole numbers are unchanged', () {
      expect(floorToTenthKg(80.0), 80.0);
    });
  });
}
