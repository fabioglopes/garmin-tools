import 'package:flutter/material.dart';
import 'garmin_auth.dart';
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
  final _name     = TextEditingController();
  final _weight   = TextEditingController();
  final _height   = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  String _sex = 'male';
  DateTime _birthDate = DateTime.utc(1990, 1, 1);
  bool _loggedIn = false;
  bool _loginInProgress = false;
  String? _loginError;

  late final String _id;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    if (p != null) {
      _id = p.id;
      _name.text   = p.name;
      _weight.text = p.expectedWeight.toString();
      _height.text = p.height.toStringAsFixed(0);
      _birthDate   = p.birthDate;
      _sex         = p.sex;
      _email.text  = p.garminEmail ?? '';
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
    final pw = await Store.readPassword(_id);
    if (mounted) setState(() => _loggedIn = pw != null && pw.isNotEmpty);
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
      if (mounted) {
        setState(() => _loginInProgress = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loginError = 'Login failed but password is saved — background '
              'uploads will retry when ready.\n\n'
              '${e.toString().replaceFirst("Exception: ", "")}';
          _loginInProgress = false;
        });
      }
    }
  }

  Future<void> _openWebViewLogin() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _loginError = 'Enter Garmin email above first.');
      return;
    }
    // WebView login can't capture password, only token. Warn the user.
    setState(() => _loginError =
        'WebView login captures the token but not the password, so auto-refresh will not work. '
        'Use the Native button instead unless you have MFA enabled.');
  }

  Future<void> _logout() async {
    await Store.clearSecrets(_id);
    if (mounted) setState(() => _loggedIn = false);
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
      garminEmail: email.isEmpty ? null : email,
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
          Row(
            children: [
              Icon(_loggedIn ? Icons.check_circle : Icons.cancel,
                  color: _loggedIn ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Text(_loggedIn ? 'Logged in' : 'Not logged in'),
            ],
          ),
          const SizedBox(height: 12),
          if (_loggedIn)
            OutlinedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
            )
          else ...[
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
          ],
          if (_loginError != null) ...[
            const SizedBox(height: 8),
            Text(_loginError!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
