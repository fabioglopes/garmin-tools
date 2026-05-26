import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'garmin_auth.dart';

class GarminWebViewLogin extends StatefulWidget {
  final Future<void> Function(String accessToken, String? refreshToken) onTokenReceived;
  const GarminWebViewLogin({super.key, required this.onTokenReceived});

  @override
  State<GarminWebViewLogin> createState() => _GarminWebViewLoginState();
}

// ── Log entry ──────────────────────────────────────────────────────────────

class _LogEntry {
  final String hms;
  final String level; // INF / OK / ERR
  final String msg;

  _LogEntry(this.level, this.msg) : hms = _now();

  static String _now() {
    final t = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  Color get color {
    if (level == 'OK') return Colors.green.shade700;
    if (level == 'ERR') return Colors.red.shade700;
    return Colors.blueGrey.shade700;
  }
}

// ── State ────────────────────────────────────────────────────────────────────

class _GarminWebViewLoginState extends State<GarminWebViewLogin> {
  late final WebViewController _controller;
  bool    _loading       = true;
  bool    _tokenCaptured = false;
  String? _lastTicket;       // dedup — ticket is single-use
  final   _logs = <_LogEntry>[];

  // clientId=GCM_IOS_DARK makes Garmin serve the mobile-app login page, which
  // renders inside an app WebView without tripping ORB (the web GarminConnect
  // page does). The service must be a PUBLICLY-RESOLVABLE host so the post-MFA
  // redirect actually completes and the ticket appears in the URL — the native
  // mobile service (mobile.integration.garmin.com) is an internal name that
  // doesn't resolve on-device, so we use connect.garmin.com instead.
  static const _service  = 'https://connect.garmin.com/modern';
  static const _loginUrl =
      'https://sso.garmin.com/sso/signin'
      '?clientId=GCM_IOS_DARK'
      '&service=$_service'
      '&gauthHost=https://sso.garmin.com/sso';

  // Full iOS Safari UA — Garmin serves the WebKit/app login page for this,
  // not the desktop/Android-WebView page that pulls in the ORB-blocked resource.
  static const _iosUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/17.5 Mobile/15E148 Safari/604.1';

  // ── Logging ──────────────────────────────────────────────────────────────

  void _log(String level, String msg) {
    // ignore: avoid_print
    print('[WebView][$level] $msg');
    if (!mounted) return;
    setState(() {
      _logs.insert(0, _LogEntry(level, msg));
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_iosUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          _log('INF', 'Loading → $url');
          if (mounted) setState(() => _loading = true);
          _tryExtractTicket(url);
        },
        onPageFinished: (url) {
          _log('INF', 'Page ready: $url');
          if (mounted) setState(() => _loading = false);
          _tryExtractTicket(url);
          // Post-MFA embed page delivers the ticket via JS, not a navigable URL.
          // Scrape it from the page HTML (reading our own DOM, no ORB).
          if (!_tokenCaptured && url.contains('sso.garmin.com/sso/')) {
            _scrapeTicketFromPage();
          }
        },
        onWebResourceError: (e) =>
            _log('ERR', 'Resource error ${e.errorCode}: ${e.description}'),
        onNavigationRequest: (req) {
          final ticket = Uri.tryParse(req.url)?.queryParameters['ticket'];
          if (ticket != null && ticket.isNotEmpty) {
            _log('INF', 'Nav has ticket → intercepting (skip dead API page)');
            _tryExtractTicket(req.url);
            return NavigationDecision.prevent; // no need to load the API host
          }
          _log('INF', 'Nav request → ${req.url}');
          return NavigationDecision.navigate;
        },
        onHttpError: (e) =>
            _log('ERR', 'HTTP ${e.response?.statusCode} → ${e.request?.uri}'),
      ))
      ..loadRequest(Uri.parse(_loginUrl));
    _log('INF', 'Initialized as iOS client — loading mobile login page');
  }

  // ── Ticket → token (native Dart HTTP, no WebView fetch, no ORB) ───────────

  void _tryExtractTicket(String url) {
    final ticket = Uri.tryParse(url)?.queryParameters['ticket'];
    if (ticket != null) _handleTicket(ticket, 'URL');
  }

  /// Reads the post-MFA page's HTML and pulls the service ticket out of it.
  /// This is how the Python `garth` library obtains the ticket — the embedded
  /// success page contains a `...?ticket=ST-xxx` reference even though it never
  /// navigates the browser there.
  Future<void> _scrapeTicketFromPage() async {
    try {
      final raw = await _controller
          .runJavaScriptReturningResult('document.documentElement.outerHTML');
      var html = raw.toString();
      // Android returns a JSON-encoded string; decode it so escapes resolve.
      if (html.startsWith('"') && html.endsWith('"')) {
        try { html = jsonDecode(html) as String; } catch (_) {}
      }
      final m = RegExp(r'ticket=(ST-[A-Za-z0-9._-]+)').firstMatch(html);
      if (m != null) {
        _handleTicket(m.group(1)!, 'page HTML');
      } else {
        // Diagnostic: is an ST- ticket present in any other form?
        final any = RegExp(r'ST-[A-Za-z0-9._-]{6,}').firstMatch(html);
        _log('INF', any != null
            ? 'ticket= not found, but saw "${any.group(0)!.substring(0, 18)}…" in HTML'
            : 'No ST- ticket in page HTML yet (${html.length} chars)');
      }
    } catch (e) {
      _log('ERR', 'Scrape failed: $e');
    }
  }

  void _handleTicket(String ticket, String source) {
    if (_tokenCaptured) return;
    if (ticket.isEmpty || ticket == _lastTicket) return;
    _lastTicket = ticket;
    _log('OK', 'SSO ticket found ($source): '
        '${ticket.length > 28 ? "${ticket.substring(0, 28)}…" : ticket}');
    _exchangeViaTicket(ticket);
  }

  Future<void> _exchangeViaTicket(String ticket) async {
    try {
      _log('INF', 'Exchanging ticket via GarminAuth.exchangeTicket…');
      final result = await GarminAuth.exchangeTicket(ticket, serviceUrl: _service);
      if (_tokenCaptured) return;
      _tokenCaptured = true;
      _log('OK', 'Token received! access: ${result.accessToken.substring(0, 20)}…  '
          'refresh: ${result.refreshToken != null ? "yes" : "none"}');
      if (mounted) setState(() {});
      await widget.onTokenReceived(result.accessToken, result.refreshToken);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _log('ERR', 'Exchange failed: $e');
      _lastTicket = null; // allow retry if the ticket appears again
    }
  }

  void _restart() {
    setState(() {
      _tokenCaptured = false;
      _lastTicket    = null;
    });
    _log('INF', '── Restart ──');
    _controller.loadRequest(Uri.parse(_loginUrl));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Garmin WebView Login'),
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
          Expanded(
            flex: 11,
            child: Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 9,
            child: _LogPanel(
              logs: _logs,
              onClear: () => setState(() => _logs.clear()),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Log panel widget ─────────────────────────────────────────────────────────

class _LogPanel extends StatelessWidget {
  final List<_LogEntry> logs;
  final VoidCallback onClear;
  const _LogPanel({required this.logs, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 2),
          child: Row(
            children: [
              const Text(
                'Exchange log',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 4),
              Text(
                '(${logs.length} entries)',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  // Stored newest-first; reverse for chronological order.
                  final text = logs.reversed
                      .map((e) => '${e.hms}  ${e.level}  ${e.msg}')
                      .join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Log copied to clipboard'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Copy', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: logs.isEmpty
              ? const Center(
                  child: Text(
                    'No events yet — log in above',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final e = logs[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e.hms} ',
                            style: const TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: Colors.grey,
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              e.level,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: e.color,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              e.msg,
                              style: TextStyle(fontSize: 10, color: e.color),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
