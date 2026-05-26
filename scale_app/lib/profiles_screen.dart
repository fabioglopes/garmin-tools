import 'package:flutter/material.dart';
import 'garmin_auth.dart';
import 'garmin_webview_login.dart';
import 'models.dart';
import 'store.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key});
  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  List<Profile> _profiles = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final p = await Store.loadProfiles();
    if (mounted) setState(() => _profiles = p);
  }

  Future<void> _addOrEdit([Profile? existing]) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ProfileEditScreen(profile: existing)),
    );
    await _reload();
  }

  Future<void> _delete(Profile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text('This removes the profile and its saved credentials. '
            'Past measurements are kept but become unassigned.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final all = await Store.loadProfiles();
    all.removeWhere((x) => x.id == p.id);
    await Store.saveProfiles(all);
    await Store.clearSecrets(p.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profiles')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addOrEdit(),
        child: const Icon(Icons.add),
      ),
      body: _profiles.isEmpty
          ? const Center(child: Text('No profiles yet. Tap + to add one.'))
          : ListView.builder(
              itemCount: _profiles.length,
              itemBuilder: (_, i) {
                final p = _profiles[i];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    title: Text(p.name),
                    subtitle: Text(
                      '~${p.expectedWeight.toStringAsFixed(1)} kg · ${p.height.toStringAsFixed(0)} cm · ${p.age}y · ${p.sex}\n'
                      '${p.hasGarmin ? "Garmin: ${p.garminEmail}" : "Garmin: not connected"}',
                    ),
                    isThreeLine: true,
                    onTap: () => _addOrEdit(p),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(p),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class ProfileEditScreen extends StatefulWidget {
  final Profile? profile;
  const ProfileEditScreen({super.key, this.profile});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _name         = TextEditingController();
  final _weight       = TextEditingController();
  final _height       = TextEditingController();
  final _email        = TextEditingController();
  final _password     = TextEditingController();
  final _manualToken  = TextEditingController();
  final _manualRefresh = TextEditingController();
  bool _showPassword    = false;
  bool _showManualPaste = false;
  String _sex = 'male';
  DateTime _birthDate = DateTime.utc(1990, 1, 1);
  bool _correctValues = false;
  bool _syncEnabled   = true;
  bool _loggedIn    = false;  // password stored (can auto-retry)
  bool _hasToken    = false;  // active OAuth token obtained
  bool _loginInProgress = false;
  String? _loginError;

  late final String _id;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    if (p != null) {
      _id = p.id;
      _name.text     = p.name;
      _weight.text   = p.expectedWeight.toString();
      _height.text   = p.height.toStringAsFixed(0);
      _birthDate     = p.birthDate;
      _sex           = p.sex;
      _correctValues = p.correctValues;
      _syncEnabled   = p.syncEnabled;
      _email.text    = p.garminEmail ?? '';
    } else {
      _id = DateTime.now().microsecondsSinceEpoch.toString();
      _weight.text = '70';
      _height.text = '175';
    }
    _loadLoginState();
  }

  Future<void> _pickBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate.toLocal(),
      firstDate: DateTime(1900),
      lastDate:  DateTime.now(),
    );
    if (picked != null) {
      setState(() => _birthDate = DateTime.utc(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _loadLoginState() async {
    final pw    = await Store.readPassword(_id);
    final token = await Store.readToken(_id);
    if (mounted) setState(() {
      _loggedIn = (pw != null && pw.isNotEmpty) || (token != null && token.isNotEmpty);
      _hasToken = token != null && token.isNotEmpty;
    });
  }

  Future<void> _doLogin() async {
    // Persist the profile first so a failed login doesn't lose the user's
    // typed-in data.
    final saved = await _persistProfile();
    if (saved == null) return;

    final email = saved.garminEmail;
    final pw = _password.text;
    if (email == null || email.isEmpty) {
      setState(() => _loginError = 'Enter Garmin email above first.');
      return;
    }
    if (pw.isEmpty) {
      setState(() => _loginError = 'Enter your Garmin password.');
      return;
    }

    // Save the password BEFORE the login attempt so a transient failure
    // (429, no network, server hiccup) doesn't lose it. The background
    // uploader can then retry whenever it needs a fresh token.
    await Store.savePassword(_id, pw);
    if (mounted) {
      setState(() {
        _loggedIn = true;
        _loginInProgress = true;
        _loginError = null;
        _password.clear();
      });
    }

    try {
      final result = await GarminAuth.login(email, pw);
      await Store.saveToken(_id, result.accessToken);
      if (mounted) setState(() { _loginInProgress = false; _hasToken = true; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loginError = e.toString().replaceFirst('Exception: ', '');
          _loginInProgress = false;
          _hasToken = false;
        });
      }
    }
  }

  Future<void> _retryLogin() async {
    final email = _email.text.trim();
    final pw    = await Store.readPassword(_id);
    if (email.isEmpty || pw == null || pw.isEmpty) {
      setState(() => _loginError = 'No stored password — log out and re-enter credentials.');
      return;
    }
    setState(() { _loginInProgress = true; _loginError = null; });
    try {
      final result = await GarminAuth.login(email, pw);
      await Store.saveToken(_id, result.accessToken);
      if (mounted) setState(() { _loginInProgress = false; _hasToken = true; });
    } catch (e) {
      if (mounted) setState(() {
        _loginError = e.toString().replaceFirst('Exception: ', '');
        _loginInProgress = false;
        _hasToken = false;
      });
    }
  }

  Future<void> _openWebViewLogin() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _loginError = 'Enter Garmin email above first.');
      return;
    }
    final saved = await _persistProfile();
    if (saved == null) return;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GarminWebViewLogin(
          onTokenReceived: (accessToken, refreshToken) async {
            await Store.saveToken(_id, accessToken);
            if (refreshToken != null && refreshToken.isNotEmpty) {
              await Store.saveRefreshToken(_id, refreshToken);
            }
            if (mounted) setState(() { _loggedIn = true; _hasToken = true; _loginError = null; });
          },
        ),
      ),
    );
  }

  void _toggleManualPaste() {
    setState(() {
      _showManualPaste = !_showManualPaste;
      _loginError = null;
    });
  }

  Future<void> _saveManualToken() async {
    final token = _manualToken.text.trim();
    if (token.isEmpty) {
      setState(() => _loginError = 'Paste the access token first.');
      return;
    }
    final saved = await _persistProfile();
    if (saved == null) return;
    await Store.saveToken(_id, token);
    final refresh = _manualRefresh.text.trim();
    if (refresh.isNotEmpty) await Store.saveRefreshToken(_id, refresh);
    _manualToken.clear();
    _manualRefresh.clear();
    if (mounted) {
      setState(() {
        _loggedIn = true;
        _hasToken = true;
        _showManualPaste = false;
        _loginError = null;
      });
    }
  }

  Future<void> _logout() async {
    await Store.clearSecrets(_id);
    if (mounted) setState(() { _loggedIn = false; _hasToken = false; _loginError = null; });
  }

  /// Validate inputs, persist to Store, return the saved profile.
  /// Returns null (and shows a snackbar) if required fields are missing.
  Future<Profile?> _persistProfile() async {
    final name = _name.text.trim();
    final weight = double.tryParse(_weight.text);
    final height = double.tryParse(_height.text);
    final email = _email.text.trim();

    if (name.isEmpty || weight == null || height == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill in name, weight, height.')),
      );
      return null;
    }

    final profile = Profile(
      id: _id,
      name: name,
      expectedWeight: weight,
      height: height,
      birthDate: _birthDate,
      sex: _sex,
      garminEmail:   email.isEmpty ? null : email,
      correctValues: _correctValues,
      syncEnabled:   _syncEnabled,
    );

    final all = await Store.loadProfiles();
    final i = all.indexWhere((p) => p.id == profile.id);
    if (i == -1) {
      all.add(profile);
    } else {
      all[i] = profile;
    }
    await Store.saveProfiles(all);
    return profile;
  }

  Future<void> _save() async {
    final saved = await _persistProfile();
    if (saved == null) return;
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile == null ? 'New profile' : 'Edit profile'),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name,   decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _weight, decoration: const InputDecoration(labelText: 'Expected weight (kg) — auto-updates after each measurement', border: OutlineInputBorder()), keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          TextField(controller: _height, decoration: const InputDecoration(labelText: 'Height (cm)', border: OutlineInputBorder()), keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickBirthDate,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Birth date', border: OutlineInputBorder()),
              child: Text(
                '${_birthDate.year}-${_birthDate.month.toString().padLeft(2, "0")}-${_birthDate.day.toString().padLeft(2, "0")}',
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'male',   label: Text('Male')),
              ButtonSegment(value: 'female', label: Text('Female')),
            ],
            selected: {_sex},
            onSelectionChanged: (v) => setState(() => _sex = v.first),
          ),
          const SizedBox(height: 32),
          SwitchListTile(
            value: _syncEnabled,
            onChanged: (v) => setState(() => _syncEnabled = v),
            title: const Text('Sync to Garmin'),
            subtitle: const Text('Uncheck to stop uploading measurements to Garmin Connect.'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _correctValues,
            onChanged: (v) => setState(() => _correctValues = v),
            title: const Text('Correct values before upload'),
            subtitle: const Text(
              'Apply calibration offsets (set in measurement detail) '
              'when sending body composition to Garmin.',
            ),
            contentPadding: EdgeInsets.zero,
          ),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Garmin (optional)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Leave blank for app-only profiles (no upload).',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            enabled: !_loggedIn && !_loginInProgress,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Garmin email', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          // ── Login status row ────────────────────────────────────────────
          _LoginStatusRow(
            loggedIn: _loggedIn,
            hasToken: _hasToken,
            inProgress: _loginInProgress,
          ),
          const SizedBox(height: 8),
          if (_loginError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade200),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _loginError!,
                style: TextStyle(fontSize: 12, color: Colors.red.shade900),
              ),
            ),
          const SizedBox(height: 8),
          if (_loggedIn) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout),
                    label: const Text('Log out'),
                  ),
                ),
                if (!_hasToken && !_loginInProgress) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _retryLogin,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry login'),
                    ),
                  ),
                ],
              ],
            ),
          ] else ...[
            TextField(
              controller: _password,
              enabled: !_loginInProgress,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Garmin password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
              onSubmitted: (_) => _loginInProgress ? null : _doLogin(),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _loginInProgress ? null : _doLogin,
              icon: _loginInProgress
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.login),
              label: Text(_loginInProgress ? 'Logging in...' : 'Login (Native)'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openWebViewLogin,
              icon: const Icon(Icons.public),
              label: const Text('Login (WebView — MFA)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _toggleManualPaste,
              icon: Icon(_showManualPaste ? Icons.keyboard_arrow_up : Icons.vpn_key_outlined),
              label: Text(_showManualPaste ? 'Hide token fields' : 'Paste token manually (MFA)'),
            ),
            if (_showManualPaste) ...[
              const SizedBox(height: 12),
              const Text(
                'Run the Python script on your desktop/Pi to get the tokens, '
                'then paste them here. Access token expires in ~1 hour.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _manualToken,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Access token',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _manualRefresh,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Refresh token (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _saveManualToken,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save token'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ── Login status row ──────────────────────────────────────────────────────────

class _LoginStatusRow extends StatelessWidget {
  final bool loggedIn;
  final bool hasToken;
  final bool inProgress;
  const _LoginStatusRow({
    required this.loggedIn,
    required this.hasToken,
    required this.inProgress,
  });

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    final String label;

    if (inProgress) {
      icon  = Icons.pending;
      color = Colors.grey;
      label = 'Connecting…';
    } else if (hasToken) {
      icon  = Icons.check_circle;
      color = Colors.green;
      label = 'Connected — active token';
    } else if (loggedIn) {
      icon  = Icons.warning_amber_rounded;
      color = Colors.orange;
      label = 'Credentials saved — no active token (token fetch failed)';
    } else {
      icon  = Icons.cancel;
      color = Colors.grey;
      label = 'Not logged in';
    }

    return Row(
      children: [
        inProgress
            ? SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: TextStyle(color: color, fontSize: 13))),
      ],
    );
  }
}
