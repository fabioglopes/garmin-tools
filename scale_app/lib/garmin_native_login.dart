import 'package:flutter/material.dart';
import 'garmin_auth.dart';

class GarminNativeLogin extends StatefulWidget {
  final void Function(String accessToken, String? refreshToken) onTokenReceived;
  const GarminNativeLogin({super.key, required this.onTokenReceived});

  @override
  State<GarminNativeLogin> createState() => _GarminNativeLoginState();
}

class _GarminNativeLoginState extends State<GarminNativeLogin> {
  final _email    = TextEditingController();
  final _password = TextEditingController();
  bool _busy      = false;
  bool _showPw    = false;
  String? _error;

  Future<void> _login() async {
    final email = _email.text.trim();
    final pw    = _password.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _error = 'Enter email and password');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final result = await GarminAuth.login(email, pw);
      if (!mounted) return;
      widget.onTokenReceived(result.accessToken, result.refreshToken);
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login to Garmin')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Icon(Icons.lock_outline, size: 48, color: Colors.blue),
            const SizedBox(height: 8),
            Text(
              'Native Login',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Credentials are sent directly to Garmin SSO using the Chromium '
              'network stack and are not stored.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _email,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: !_showPw,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPw = !_showPw),
                ),
              ),
              onSubmitted: (_) => _busy ? null : _login(),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _login,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.login),
              label: Text(_busy ? 'Logging in...' : 'Login'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
