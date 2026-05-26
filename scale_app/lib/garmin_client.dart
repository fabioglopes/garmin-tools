import 'package:dio/dio.dart';
import 'fit_encoder.dart';
import 'garmin_auth.dart';

/// Garmin Connect uploader with automatic token refresh.
///
/// Holds the user's credentials so it can re-login transparently when the
/// access token expires (Garmin returns 401). The optional `onTokenRefreshed`
/// callback fires whenever a fresh token is obtained, so the caller can
/// persist it.
class GarminClient {
  final String  email;
  final String? password; // null for MFA/token-only profiles
  final void Function(String accessToken, String? refreshToken)? onTokenRefreshed;

  String? _token;
  String? _refreshToken;
  final Dio _dio;

  GarminClient({
    required this.email,
    this.password,
    String? token,
    String? refreshToken,
    this.onTokenRefreshed,
  })  : _token = token,
        _refreshToken = refreshToken,
        _dio = Dio(BaseOptions(
          headers: {
            'Accept':                   'application/json',
            'User-Agent':               'GCM-Android-5.23',
            'X-Garmin-User-Agent':      'com.garmin.android.apps.connectmobile/5.23; ; Google/Pixel 6/google; Android/33; Dalvik/2.1.0',
            'X-App-Ver':                '10861',
            'X-Garmin-Client-Platform': 'Android',
            'NK': 'NT',
          },
          validateStatus: (_) => true,
        ));

  String? get currentToken => _token;

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

    final bytes = (FitEncoder()
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
          ))
        .encode();

    if (_token == null) await _refresh();

    var resp = await _doUpload(bytes);
    if (resp.statusCode == 401) {
      // Token expired — refresh and retry once
      await _refresh();
      resp = await _doUpload(bytes);
    }

    if (resp.statusCode == 401) {
      throw Exception('Garmin rejected the token (401). Re-login in the profile '
          '(WebView/MFA) or paste a fresh token.');
    }
    if ((resp.statusCode ?? 500) >= 400) {
      final preview = resp.data?.toString() ?? '';
      final clipped = preview.length > 200 ? '${preview.substring(0, 200)}...' : preview;
      throw Exception('Upload failed (HTTP ${resp.statusCode}): $clipped');
    }

    final data = resp.data;
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  Future<Response> _doUpload(List<int> bytes) {
    return _dio.post(
      'https://connectapi.garmin.com/upload-service/upload/.fit',
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'body_composition.fit'),
      }),
      options: Options(headers: {'Authorization': 'Bearer $_token'}),
    );
  }

  Future<void> _refresh() async {
    // Prefer the refresh token — it works without a password, so MFA/token-only
    // profiles keep uploading until the refresh token expires (~1 year).
    if (_refreshToken != null && _refreshToken!.isNotEmpty) {
      try {
        final r = await GarminAuth.refreshAccessToken(_refreshToken!);
        _token        = r.accessToken;
        _refreshToken = r.refreshToken ?? _refreshToken;
        onTokenRefreshed?.call(_token!, _refreshToken);
        return;
      } catch (e) {
        // Refresh token expired/revoked — fall back to password if we have one.
        if (password == null || password!.isEmpty) {
          throw Exception('Token refresh failed and no password is stored. '
              'Re-login in the profile (WebView/MFA) or paste a fresh token. ($e)');
        }
      }
    }

    if (password == null || password!.isEmpty) {
      throw Exception('Token expired and no refresh token or password is stored. '
          'Open the profile and log in again (WebView/MFA) or paste a fresh token.');
    }
    final r = await GarminAuth.login(email, password!);
    _token        = r.accessToken;
    _refreshToken = r.refreshToken ?? _refreshToken;
    onTokenRefreshed?.call(r.accessToken, r.refreshToken);
  }
}
