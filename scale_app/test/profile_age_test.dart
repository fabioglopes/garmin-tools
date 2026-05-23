import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/models.dart';

Profile _p(DateTime birth) => Profile(
  id: 't', name: 't', expectedWeight: 70,
  height: 170, birthDate: birth, sex: 'male',
);

void main() {
  group('Profile.ageOn', () {
    test('full years between birth and date', () {
      final p = _p(DateTime.utc(1980, 6, 15));
      expect(p.ageOn(DateTime.utc(2024, 6, 15)), 44);  // exact birthday
      expect(p.ageOn(DateTime.utc(2024, 6, 14)), 43);  // day before
      expect(p.ageOn(DateTime.utc(2024, 6, 16)), 44);  // day after
    });

    test('birthday later in year — month checked', () {
      final p = _p(DateTime.utc(1980, 12, 1));
      expect(p.ageOn(DateTime.utc(2024, 11, 30)), 43);
      expect(p.ageOn(DateTime.utc(2024, 12, 1)),  44);
    });

    test('historical measurement gets historical age', () {
      final p = _p(DateTime.utc(1980, 1, 1));
      expect(p.ageOn(DateTime.utc(2010, 1, 1)), 30);
      expect(p.ageOn(DateTime.utc(2025, 1, 1)), 45);
    });
  });
}
