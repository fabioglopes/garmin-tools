import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class GarminWebViewLogin extends StatefulWidget {
  final void Function(String accessToken, String? refreshToken) onTokenReceived;
  const GarminWebViewLogin({super.key, required this.onTokenReceived});

  @override
  State<GarminWebViewLogin> createState() => _GarminWebViewLoginState();
}

class _GarminWebViewLoginState extends State<GarminWebViewLogin> {
  late final WebViewController _controller;
  bool _loading        = true;
  bool _tokenCaptured  = false;
  bool _exchangeFired  = false;
  String _status       = 'Log in with your Garmin account';

  static const _loginUrl =
      'https://sso.garmin.com/sso/signin'
      '?service=https://connect.garmin.com/modern'
      '&clientId=GarminConnect'
      '&gauthHost=https://sso.garmin.com/sso';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('GarminToken', onMessageReceived: _onJsMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          print('[WebView] loading: $url');
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: _onPageFinished,
        onWebResourceError: (e) => print('[WebView] error: ${e.description}'),
      ))
      ..loadRequest(Uri.parse(_loginUrl));
  }

  void _onJsMessage(JavaScriptMessage msg) {
    if (_tokenCaptured) return;
    final raw = msg.message;
    print('[WebView] JS: ${raw.length > 200 ? '${raw.substring(0, 200)}...' : raw}');

    if (raw.startsWith('OK:')) {
      try {
        final data    = jsonDecode(raw.substring(3)) as Map<String, dynamic>;
        final token   = data['access_token']  as String?;
        final refresh = data['refresh_token'] as String?;
        if (token != null && token.isNotEmpty) {
          _tokenCaptured = true;
          widget.onTokenReceived(token, refresh);
          return;
        }
        setState(() => _status = 'Login OK but no access_token in response');
      } catch (e) {
        setState(() => _status = 'Parse error: $e');
      }
    } else if (raw.startsWith('ERR:')) {
      setState(() {
        _status = 'Exchange failed: ${raw.substring(4)}';
        _exchangeFired = false;
      });
    }
  }

  Future<void> _onPageFinished(String url) async {
    print('[WebView] finished: $url');
    if (mounted) setState(() => _loading = false);
    if (_tokenCaptured || _exchangeFired) return;

    // Once user has been redirected to connect.garmin.com (not signin), the
    // session is established. Trigger the OAuth exchange via fetch() POST so
    // we get the token back through the JS channel (more reliable than
    // navigating to the URL and scraping document.body).
    if (url.startsWith('https://connect.garmin.com') && !url.contains('signin')) {
      _exchangeFired = true;
      setState(() => _status = 'Logged in! Exchanging for token...');
      await Future.delayed(const Duration(milliseconds: 500));
      await _controller.runJavaScript('''
        fetch('/modern/di-oauth/exchange', {
          method: 'POST',
          credentials: 'include',
          headers: {'NK': 'NT'}
        })
        .then(r => r.text())
        .then(t => GarminToken.postMessage('OK:' + t))
        .catch(e => GarminToken.postMessage('ERR:' + e.toString()));
      ''');
    }
  }

  void _restart() {
    setState(() {
      _exchangeFired = false;
      _tokenCaptured = false;
      _status        = 'Log in with your Garmin account';
    });
    _controller.loadRequest(Uri.parse(_loginUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login to Garmin (WebView)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Restart',
            onPressed: _restart,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: _status.contains('failed') || _status.contains('error')
                ? Colors.red.shade50
                : Colors.blue.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(_status, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
