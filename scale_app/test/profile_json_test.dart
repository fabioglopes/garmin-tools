import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:scale_app/models.dart';

void main() {
  group('Profile JSON', () {
    test('round-trips losslessly', () {
      final p = Profile(
        id: 'abc',
        name: 'Fabio',
        expectedWeight: 75.5,
        height: 173,
        birthDate: DateTime.utc(1980, 6, 15),
        sex: 'male',
        garminEmail: 'me@example.com',
      );
      final json = jsonEncode(p.toJson());
      final back = Profile.fromJson(jsonDecode(json) as Map<String, dynamic>);

      expect(back.id,             p.id);
      expect(back.name,           p.name);
      expect(back.expectedWeight, p.expectedWeight);
      expect(back.height,         p.height);
      expect(back.birthDate,      p.birthDate);
      expect(back.sex,            p.sex);
      expect(back.garminEmail,    p.garminEmail);
    });

    test('null garminEmail round-trips', () {
      final p = Profile(
        id: 'x', name: 'App-only', expectedWeight: 60,
        height: 165, birthDate: DateTime.utc(1990, 1, 1),
        sex: 'female',
      );
      final back = Profile.fromJson(p.toJson());
      expect(back.garminEmail, isNull);
      expect(back.hasGarmin,   isFalse);
    });

    test('round-tripped list of profiles preserves order and identity', () {
      final list = [
        Profile(id: '1', name: 'a', expectedWeight: 70, height: 170,
                birthDate: DateTime.utc(1990,1,1), sex: 'male'),
        Profile(id: '2', name: 'b', expectedWeight: 60, height: 165,
                birthDate: DateTime.utc(1985,3,3), sex: 'female'),
      ];
      final encoded = jsonEncode(list.map((p) => p.toJson()).toList());
      final decoded = (jsonDecode(encoded) as List)
          .map((j) => Profile.fromJson(j as Map<String, dynamic>))
          .toList();
      expect(decoded.length, 2);
      expect(decoded[0].id,  '1');
      expect(decoded[1].id,  '2');
      expect(decoded[1].name, 'b');
    });

    test('legacy `age` field is converted to a plausible birth date', () {
      // Old-format JSON without `birth_date`
      final json = {
        'id': 'old',
        'name': 'Legacy',
        'expected_weight': 75.0,
        'height': 173.0,
        'age': 40,
        'sex': 'male',
        'garmin_email': null,
      };
      final p = Profile.fromJson(json);
      // Computed age should match the stored age within rounding
      expect(p.age, 40);
    });

    test('missing birth_date AND age defaults instead of crashing', () {
      final json = {
        'id': 'broken',
        'name': 'Broken',
        'expected_weight': 70.0,
        'height': 170.0,
        'sex': 'male',
      };
      expect(() => Profile.fromJson(json), returnsNormally);
    });
  });
}
