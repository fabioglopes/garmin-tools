import 'dart:convert';
import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

class GarminAuthResult {
  final String accessToken;
  final String? refreshToken;
  GarminAuthResult(this.accessToken, this.refreshToken);
}

/// Replicates the login flow from https://github.com/cyberjunky/python-garminconnect
/// Strategy: mobile iOS JSON login → DI OAuth2 token exchange
/// No CSRF scraping, no OAuth1, no cookies needed.
class GarminAuth {
  static const _mobileService  = 'https://mobile.integration.garmin.com/gcm/ios';
  static const _mobileClientId = 'GCM_IOS_DARK';
  static const _diTokenUrl     = 'https://diauth.garmin.com/di-oauth2-service/oauth/token';
  static const _diGrantType    = 'https://connectapi.garmin.com/di-oauth2-service/oauth/grant/service_ticket';

  static Future<GarminAuthResult> login(String email, String password) async {
    final engine = CronetEngine.build(
      cacheMode: CacheMode.disabled,
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    );
    final client = CronetClient.fromCronetEngine(engine);

    try {
      // ── Step 1: JSON login → serviceTicketId ─────────────────────────────
      final loginUri = Uri.https('sso.garmin.com', '/mobile/api/login', {
        'clientId': _mobileClientId,
        'locale':   'en-US',
        'service':  _mobileService,
      });

      final loginReq = http.Request('POST', loginUri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept']       = 'application/json, text/plain, */*'
        ..headers['Origin']       = 'https://sso.garmin.com'
        ..body = jsonEncode({
          'username':    email,
          'password':    password,
          'rememberMe':  true,
          'captchaToken': '',
        });

      final loginResp = await _send(client, loginReq);
      if (loginResp.statusCode != 200) {
        final preview = _clip(loginResp.body, 200);
        throw Exception(
          'Login failed (HTTP ${loginResp.statusCode}). '
          '${preview.isEmpty ? "Cloudflare may be blocking — try the WebView login." : preview}',
        );
      }

      final loginData = _safeJsonObject(loginResp.body)
          ?? (throw Exception(
                'Unexpected login response (not JSON object): ${_clip(loginResp.body, 200)}'));

      final responseStatus = loginData['responseStatus'];
      final statusType = responseStatus is Map ? responseStatus['type'] as String? : null;

      if (statusType == 'MFA_REQUIRED') {
        throw Exception(
          'Your Garmin account has MFA enabled. '
          'Please use the WebView login instead.',
        );
      }
      if (statusType != 'SUCCESSFUL') {
        final msg = responseStatus is Map ? responseStatus['message'] as String? : null;
        throw Exception(
          statusType == 'INVALID_USERNAME_PASSWORD' || (statusType?.contains('INVALID') ?? false)
              ? 'Wrong email or password.'
              : 'Login failed (status: $statusType${msg != null ? " — $msg" : ""})',
        );
      }

      final ticket = loginData['serviceTicketId'] as String?;
      if (ticket == null || ticket.isEmpty) {
        throw Exception('Login succeeded but no serviceTicketId in response.');
      }

      // ── Step 2: Exchange ticket for DI OAuth2 bearer token ────────────────
      // The service ticket is single-use, so we only get one shot per login.
      // Use the iOS DI client ID to match our iOS SSO strategy.
      return await _exchangeTicket(client, ticket, 'GARMIN_CONNECT_MOBILE_IOS_DI');
    } finally {
      client.close();
    }
  }

  static Future<GarminAuthResult> _exchangeTicket(
    http.Client client, String ticket, String diClientId,
  ) async {
    final authHeader = 'Basic ${base64.encode(utf8.encode('$diClientId:'))}';

    final req = http.Request('POST', Uri.parse(_diTokenUrl))
      ..headers['Authorization'] = authHeader
      ..headers['Content-Type']  = 'application/x-www-form-urlencoded'
      ..headers['Accept']        = 'application/json,text/html;q=0.9,*/*;q=0.8'
      ..headers['User-Agent']    = 'GCM-iOS-5.23'
      ..bodyFields = {
        'client_id':      diClientId,
        'service_ticket': ticket,
        'grant_type':     _diGrantType,
        'service_url':    _mobileService,
      };

    final resp = await _send(client, req);
    if (resp.statusCode != 200) {
      throw Exception('DI exchange failed (${resp.statusCode}): ${_clip(resp.body, 200)}');
    }

    final data = _safeJsonObject(resp.body)
        ?? (throw Exception('DI exchange response not JSON object: ${_clip(resp.body, 200)}'));

    final accessToken = data['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('DI response missing access_token: ${_clip(resp.body, 200)}');
    }
    return GarminAuthResult(accessToken, data['refresh_token'] as String?);
  }

  static Map<String, dynamic>? _safeJsonObject(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String _clip(String s, int n) =>
      s.length > n ? '${s.substring(0, n)}...' : s;

  static Future<http.Response> _send(http.Client client, http.Request req) async {
    req.followRedirects = false;
    req.maxRedirects    = 0;
    final streamed = await client.send(req);
    final resp     = await http.Response.fromStream(streamed);
    // Follow a single redirect if needed (e.g. 301 HTTPS upgrade)
    if (resp.statusCode >= 300 && resp.statusCode < 400) {
      final loc = resp.headers['location'];
      if (loc != null) {
        final next = http.Request(req.method, req.url.resolve(loc))
          ..headers.addAll(req.headers);
        if (req.body.isNotEmpty) next.body = req.body;
        return _send(client, next);
      }
    }
    return resp;
  }
}
