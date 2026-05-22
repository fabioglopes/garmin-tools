import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'background_service.dart';
import 'garmin_client.dart';
import 'garmin_native_login.dart';
import 'garmin_webview_login.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  await _initService();
  runApp(const ScaleApp());
}

Future<void> _initNotifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(const InitializationSettings(android: android));

  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'scale_channel', 'Scale Monitor',
        description: 'Background scale monitoring',
        importance: Importance.low,
      ));
  await plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'scale_results', 'Scale Results',
        importance: Importance.high,
      ));
}

Future<void> _initService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'scale_channel',
      initialNotificationTitle: 'Scale Monitor',
      initialNotificationContent: 'Listening for Xiaomi scale...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

class ScaleApp extends StatelessWidget {
  const ScaleApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Scale → Garmin',
    theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service  = FlutterBackgroundService();
  final _storage  = const FlutterSecureStorage();
  bool _running   = false;
  Map<String, dynamic>? _last;
  bool _syncing   = false;
  DateTime? _syncedAt;
  String? _syncError;

  @override
  void initState() {
    super.initState();
    _checkRunning();
    _service.on('measurement').listen((data) {
      if (data != null) setState(() { _last = data; _syncedAt = null; _syncError = null; });
    });
  }

  Future<void> _checkRunning() async {
    final r = await _service.isRunning();
    setState(() => _running = r);
  }

  Future<void> _toggle() async {
    if (_running) {
      _service.invoke('stop');
      setState(() => _running = false);
      return;
    }

    // Request BLE + notification permissions
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    final token = await _storage.read(key: 'garmin_access_token') ?? '';
    if (token.isEmpty) {
      _openSettings('Login to Garmin first — open Settings');
      return;
    }

    await _service.startService();
    setState(() => _running = true);
  }

  void _openSettings([String? hint]) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(hint: hint)));
  }

  Future<void> _sync() async {
    if (_last == null || _syncing) return;
    setState(() { _syncing = true; _syncError = null; });
    try {
      final token  = await _storage.read(key: 'garmin_access_token') ?? '';
      final height = double.tryParse(await _storage.read(key: 'height') ?? '175') ?? 175;
      if (token.isEmpty) throw Exception('Not logged in — open Settings → Login to Garmin');

      final client = GarminClient(token);
      await client.uploadBodyComposition(
        timestamp: DateTime.parse(_last!['timestamp']),
        weight:    (_last!['weight'] as num).toDouble(),
        height:    height,
        percentFat:       (_last!['fat_pct'] as num?)?.toDouble(),
        percentHydration: (_last!['water_pct'] as num?)?.toDouble(),
        muscleKg:         (_last!['muscle_kg'] as num?)?.toDouble(),
      );
      setState(() { _syncedAt = DateTime.now(); _syncing = false; });
    } catch (e) {
      setState(() { _syncError = e.toString(); _syncing = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scale → Garmin'),
        actions: [IconButton(icon: const Icon(Icons.settings), onPressed: () => _openSettings())],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _running ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
                size: 80,
                color: _running ? Colors.blue : Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                _running ? 'Listening for scale...' : 'Service stopped',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (_running)
                Text('Step on scale with bare feet', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _toggle,
                icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                label: Text(_running ? 'Stop' : 'Start'),
                style: FilledButton.styleFrom(
                  backgroundColor: _running ? Colors.red : Colors.blue,
                  minimumSize: const Size(180, 52),
                ),
              ),
              if (_last != null) ...[
                const SizedBox(height: 48),
                _MeasurementCard(
                  data:      _last!,
                  onSync:    _syncedAt == null ? _sync : null,
                  syncing:   _syncing,
                  syncedAt:  _syncedAt,
                  syncError: _syncError,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MeasurementCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback? onSync;
  final bool syncing;
  final DateTime? syncedAt;
  final String? syncError;

  const _MeasurementCard({
    required this.data,
    required this.onSync,
    required this.syncing,
    required this.syncedAt,
    required this.syncError,
  });

  @override
  Widget build(BuildContext context) {
    final alreadySynced = syncedAt != null;
    final h = syncedAt?.hour.toString().padLeft(2, '0');
    final m = syncedAt?.minute.toString().padLeft(2, '0');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Last measurement', style: Theme.of(context).textTheme.titleMedium),
            Text(_formatLocal(data['timestamp']), style: Theme.of(context).textTheme.bodySmall),
            const Divider(),
            _row('Weight',  '${data['weight']?.toStringAsFixed(2)} ${data['unit']}'),
            if (data['fat_pct'] != null)   _row('Body fat', '${data['fat_pct']}%'),
            if (data['muscle_kg'] != null) _row('Muscle',   '${data['muscle_kg']} kg'),
            if (data['water_pct'] != null) _row('Water',    '${data['water_pct']}%'),
            if (data['bmi'] != null)       _row('BMI',      '${data['bmi']}'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: alreadySynced || syncing ? null : onSync,
              icon: syncing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(alreadySynced ? Icons.check : Icons.cloud_upload),
              label: Text(
                syncing      ? 'Syncing...'
                : alreadySynced ? 'Synced at $h:$m'
                : 'Sync to Garmin',
              ),
            ),
            if (syncError != null) ...[
              const SizedBox(height: 8),
              Text(syncError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatLocal(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      String pad(int n) => n.toString().padLeft(2, '0');
      return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
    } catch (_) {
      return iso;
    }
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  final String? hint;
  const SettingsScreen({super.key, this.hint});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _storage = const FlutterSecureStorage();
  final _height  = TextEditingController();
  final _age     = TextEditingController();
  String _sex    = 'male';
  bool _loggedIn = false;
  bool _saved    = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _height.text = await _storage.read(key: 'height') ?? '175';
    _age.text    = await _storage.read(key: 'age')    ?? '30';
    final sex    = await _storage.read(key: 'sex')    ?? 'male';
    final token  = await _storage.read(key: 'garmin_access_token') ?? '';
    setState(() { _sex = sex; _loggedIn = token.isNotEmpty; });
  }

  Future<void> _saveToken(String token, String? refresh) async {
    await _storage.write(key: 'garmin_access_token', value: token);
    if (refresh != null) await _storage.write(key: 'garmin_refresh_token', value: refresh);
    if (!mounted) return;
    setState(() => _loggedIn = true);
    Navigator.pop(context);
  }

  Future<void> _openNativeLogin() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => GarminNativeLogin(onTokenReceived: _saveToken),
    ));
  }

  Future<void> _openWebViewLogin() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => GarminWebViewLogin(onTokenReceived: _saveToken),
    ));
  }

  Future<void> _logout() async {
    await _storage.delete(key: 'garmin_access_token');
    await _storage.delete(key: 'garmin_refresh_token');
    setState(() => _loggedIn = false);
  }

  Future<void> _save() async {
    await _storage.write(key: 'height', value: _height.text.trim());
    await _storage.write(key: 'age',    value: _age.text.trim());
    await _storage.write(key: 'sex',    value: _sex);
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(widget.hint!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),

          const Text('Garmin Account', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(_loggedIn ? Icons.check_circle : Icons.cancel, color: _loggedIn ? Colors.green : Colors.grey),
              const SizedBox(width: 8),
              Text(_loggedIn ? 'Connected to Garmin' : 'Not connected'),
            ],
          ),
          const SizedBox(height: 12),
          if (_loggedIn)
            OutlinedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('Disconnect'),
            )
          else ...[
            FilledButton.icon(
              onPressed: _openNativeLogin,
              icon: const Icon(Icons.login),
              label: const Text('Login (Native, email + password)'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openWebViewLogin,
              icon: const Icon(Icons.public),
              label: const Text('Login (WebView fallback)'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
            const SizedBox(height: 8),
            Text(
              'Try Native first — it uses the Chromium network stack and works '
              'like the Python script. WebView is a fallback if Native fails.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],

          const SizedBox(height: 32),
          const Text('Body Profile', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(controller: _height, decoration: const InputDecoration(labelText: 'Height (cm)', border: OutlineInputBorder()), keyboardType: TextInputType.number),
          const SizedBox(height: 12),
          TextField(controller: _age,    decoration: const InputDecoration(labelText: 'Age',         border: OutlineInputBorder()), keyboardType: TextInputType.number),
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
          FilledButton(
            onPressed: _save,
            child: Text(_saved ? 'Saved ✓' : 'Save'),
          ),
        ],
      ),
    );
  }
}
