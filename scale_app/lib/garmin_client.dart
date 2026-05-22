import 'package:dio/dio.dart';
import 'fit_encoder.dart';

class GarminClient {
  final Dio _dio;

  GarminClient(String accessToken)
      : _dio = Dio(BaseOptions(
          headers: {
            'Authorization':          'Bearer $accessToken',
            'Accept':                 'application/json',
            'User-Agent':             'GCM-Android-5.23',
            'X-Garmin-User-Agent':    'com.garmin.android.apps.connectmobile/5.23; ; Google/Pixel 6/google; Android/33; Dalvik/2.1.0',
            'X-App-Ver':              '10861',
            'X-Garmin-Client-Platform': 'Android',
            'NK': 'NT',
          },
          validateStatus: (_) => true, // we handle all status codes manually
        ));

  Future<Map<String, dynamic>> uploadBodyComposition({
    required DateTime timestamp,
    required double weight,
    required double height,
    double? percentFat,
    double? percentHydration,
    double? muscleKg,
    double? boneKg,
  }) async {
    final bmi = weight / ((height / 100) * (height / 100));

    final encoder = FitEncoder()
      ..writeFileId(timestamp)
      ..writeFileCreator()
      ..writeDeviceInfo(timestamp)
      ..writeWeightScale(
        dt: timestamp,
        weight: weight,
        percentFat: percentFat,
        percentHydration: percentHydration,
        muscleKg: muscleKg,
        boneKg: boneKg,
        bmi: bmi,
      );

    final resp = await _dio.post(
      'https://connectapi.garmin.com/upload-service/upload/.fit',
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(encoder.encode(), filename: 'body_composition.fit'),
      }),
    );

    if (resp.statusCode == 401) {
      throw Exception('Token expired — please login again in Settings');
    }
    if ((resp.statusCode ?? 500) >= 400) {
      final preview = resp.data?.toString() ?? '';
      final clipped = preview.length > 200 ? '${preview.substring(0, 200)}...' : preview;
      throw Exception('Upload failed (HTTP ${resp.statusCode}): $clipped');
    }

    final data = resp.data;
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }
}
