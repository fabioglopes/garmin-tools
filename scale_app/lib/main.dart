import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'background_service.dart';
import 'debug_screen.dart';
import 'measurement_detail_screen.dart';
import 'models.dart';
import 'profiles_screen.dart';
import 'store.dart';
import 'uploader.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  await _initService();
  runApp(const ScaleApp());
}

Future<void> _initNotifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: onNotificationAction,
    onDidReceiveBackgroundNotificationResponse: onNotificationAction,
  );

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
  final _service = FlutterBackgroundService();
  bool _running = false;
  List<Profile> _profiles = [];
  List<Measurement> _measurements = [];
  Map<String, dynamic>? _pending; // first stabilized packet, buffer still open

  @override
  void initState() {
    super.initState();
    _checkRunning();
    _reload();
    _service.on('pending_measurement').listen((data) {
      if (data != null && mounted) setState(() => _pending = data);
    });
    _service.on('measurement').listen((_) {
      if (mounted) setState(() => _pending = null);
      _reload();
    });
  }

  Future<void> _checkRunning() async {
    final r = await _service.isRunning();
    if (mounted) setState(() => _running = r);
  }

  Future<void> _reload() async {
    final profiles = await Store.loadProfiles();
    final measurements = await Store.loadMeasurements();
    measurements.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _measurements = measurements;
      });
    }
  }

  Future<void> _toggle() async {
    if (_running) {
      _service.invoke('stop');
      setState(() => _running = false);
      return;
    }

    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    if (_profiles.isEmpty) {
      _snack('Add a profile first — tap the people icon.');
      return;
    }

    await _service.startService();
    setState(() => _running = true);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openProfiles() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilesScreen()));
    await _reload();
  }

  Future<void> _deleteMeasurement(Measurement m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete measurement?'),
        content: Text(
          '${m.weight.toStringAsFixed(2)} ${m.unit} '
          '${m.synced ? "(already synced to Garmin — deletion only removes the local copy)" : ""}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Store.deleteMeasurement(m.id);
    await _reload();
  }

  Future<void> _syncMeasurement(Measurement m) async {
    final profile = _profileFor(m);
    if (profile == null) {
      _snack('Assign a profile first.');
      return;
    }
    if (!profile.hasGarmin) {
      _snack('${profile.name} has no Garmin account.');
      return;
    }
    _snack('Syncing ${profile.name}...');
    try {
      await uploadMeasurement(profile, m);
      await _reload();
      if (mounted) _snack('${profile.name} → Garmin ✓');
    } catch (e) {
      await _reload();
      if (mounted) _snack('Sync failed: $e');
    }
  }

  Future<void> _assignMeasurement(Measurement m) async {
    if (_profiles.isEmpty) {
      _snack('Add a profile first.');
      return;
    }
    final picked = await showDialog<Profile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Assign to profile'),
        children: [
          for (final p in _profiles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text('${p.name} (~${p.expectedWeight.toStringAsFixed(1)} kg)'),
            ),
        ],
      ),
    );
    if (picked == null) return;
    m.profileId = picked.id;
    await Store.updateMeasurement(m);
    await _reload();
  }

  Profile? _profileFor(Measurement m) {
    if (m.profileId == null) return null;
    try {
      return _profiles.firstWhere((p) => p.id == m.profileId);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scale → Garmin'),
        actions: [
          if (_pending != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Live BLE events',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugScreen()),
            ),
          ),
          IconButton(icon: const Icon(Icons.people), onPressed: _openProfiles),
        ],
      ),
      body: Column(
        children: [
          _StatusBar(running: _running, onToggle: _toggle),
          Expanded(
            child: _measurements.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No measurements yet.\nStep on the scale with bare feet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _measurements.length + (_pending != null ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (_pending != null && i == 0) {
                        return _PendingTile(pending: _pending!);
                      }
                      final m = _measurements[_pending != null ? i - 1 : i];
                      final profile = _profileFor(m);
                      return _MeasurementTile(
                        m: m,
                        profile: profile,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MeasurementDetailScreen(
                                measurement: m,
                                profile: profile,
                              ),
                            ),
                          );
                          await _reload();
                        },
                        onAssign: () => _assignMeasurement(m),
                        onSync:   () => _syncMeasurement(m),
                        onDelete: () => _deleteMeasurement(m),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final bool running;
  final VoidCallback onToggle;
  const _StatusBar({required this.running, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: running ? Colors.blue.withValues(alpha: 0.1) : null,
      child: Row(
        children: [
          Icon(
            running ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
            color: running ? Colors.blue : Colors.grey,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(running ? 'Listening for scale...' : 'Service stopped')),
          FilledButton.icon(
            onPressed: onToggle,
            icon: Icon(running ? Icons.stop : Icons.play_arrow),
            label: Text(running ? 'Stop' : 'Start'),
            style: FilledButton.styleFrom(backgroundColor: running ? Colors.red : Colors.blue),
          ),
        ],
      ),
    );
  }
}

class _MeasurementTile extends StatelessWidget {
  final Measurement m;
  final Profile? profile;
  final VoidCallback onTap;
  final VoidCallback onAssign;
  final VoidCallback onSync;
  final VoidCallback onDelete;
  const _MeasurementTile({
    required this.m,
    required this.profile,
    required this.onTap,
    required this.onAssign,
    required this.onSync,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dt = m.timestamp.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    final dateStr =
        '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';

    final unassigned = profile == null;
    final title = unassigned
        ? '${m.weight.toStringAsFixed(2)} ${m.unit} — unassigned'
        : '${profile!.name} — ${m.weight.toStringAsFixed(2)} ${m.unit}';

    final canSync = !unassigned && profile!.hasGarmin && profile!.syncEnabled && !m.synced;

    final action = unassigned
        ? FilledButton(onPressed: onAssign, child: const Text('Assign'))
        : canSync
            ? FilledButton.icon(
                onPressed: onSync,
                icon: const Icon(Icons.cloud_upload, size: 18),
                label: const Text('Sync'),
              )
            : null;

    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (action != null) action,
        IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          tooltip: 'Delete',
          onPressed: onDelete,
        ),
      ],
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: onTap,
        title: Text(
          title,
          style: TextStyle(
            color: unassigned ? Colors.orange : null,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dateStr),
            if (m.fatPct != null) Text('Fat ${m.fatPct}% · Muscle ${m.muscleKg} kg · BMI ${m.bmi}'),
            _SyncStatus(m: m, profile: profile),
          ],
        ),
        trailing: trailing,
        isThreeLine: true,
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  final Map<String, dynamic> pending;
  const _PendingTile({required this.pending});

  @override
  Widget build(BuildContext context) {
    final weight = (pending['weight'] as num).toDouble();
    final unit   = pending['unit'] as String;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const SizedBox(
          width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(
          '${weight.toStringAsFixed(2)} $unit',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: const Text('Collecting body composition data...'),
        trailing: const Icon(Icons.hourglass_top, color: Colors.grey),
      ),
    );
  }
}

class _SyncStatus extends StatelessWidget {
  final Measurement m;
  final Profile? profile;
  const _SyncStatus({required this.m, required this.profile});

  @override
  Widget build(BuildContext context) {
    String pad(int n) => n.toString().padLeft(2, '0');

    if (m.synced && m.syncedAt != null) {
      final t = m.syncedAt!.toLocal();
      return Text(
        'Synced ✓ ${pad(t.hour)}:${pad(t.minute)}',
        style: const TextStyle(color: Colors.green, fontSize: 12),
      );
    }
    if (m.syncError != null) {
      return Text(
        'Sync failed: ${m.syncError}',
        style: const TextStyle(color: Colors.red, fontSize: 12),
      );
    }
    if (profile == null) {
      return const Text('Unassigned — pick a profile', style: TextStyle(color: Colors.orange, fontSize: 12));
    }
    if (!profile!.hasGarmin) {
      return const Text('App-only — no Garmin upload', style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    if (!profile!.syncEnabled) {
      return const Text('Sync disabled', style: TextStyle(color: Colors.orange, fontSize: 12));
    }
    return const Text('Not synced', style: TextStyle(color: Colors.grey, fontSize: 12));
  }
}
