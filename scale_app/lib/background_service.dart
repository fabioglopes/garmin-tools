import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'garmin_client.dart';

const _scaleUuid = '0000181b-0000-1000-8000-00805f9b34fb';
const _cooldownSeconds = 300;

int _lastUploadTime = 0;
String? _lastSeenKey;

@pragma('vm:entry-point')
void onServiceStart(ServiceInstance service) async {
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  service.on('stop').listen((_) {
    FlutterBluePlus.stopScan();
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Scale Monitor',
      content: 'Listening for Xiaomi scale...',
    );
  }

  // Wait for Bluetooth to be ready
  FlutterBluePlus.setLogLevel(LogLevel.error);
  await FlutterBluePlus.adapterState
      .where((s) => s == BluetoothAdapterState.on)
      .first
      .timeout(const Duration(seconds: 15), onTimeout: () => BluetoothAdapterState.unknown);

  final btState = await FlutterBluePlus.adapterState.first;
  print('[Scale] Bluetooth state: $btState');

  if (btState != BluetoothAdapterState.on) {
    _notify(notifications, 'Scale Monitor', 'Bluetooth is off — turn it on and restart the service.');
    service.stopSelf();
    return;
  }

  await _runScanLoop(service, notifications);
}

Future<void> _runScanLoop(ServiceInstance service, FlutterLocalNotificationsPlugin notifications) async {
  while (true) {
    try {
      await _scanOnce(service, notifications);
    } catch (e) {
      print('[Scale] Scan error: $e');
    }
    await Future.delayed(const Duration(seconds: 5));
  }
}

Future<void> _scanOnce(ServiceInstance service, FlutterLocalNotificationsPlugin notifications) async {
  final completer = Completer<void>();

  print('[Scale] Starting BLE scan...');
  try {
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 30),
    );
  } catch (e) {
    print('[Scale] startScan error: $e');
    return;
  }
  print('[Scale] Scan started');

  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final result in results) {
      print('[Scale] Found device: ${result.device.remoteId} services=${result.advertisementData.serviceData.keys.toList()}');
      final uuid = Guid(_scaleUuid);
      final data = result.advertisementData.serviceData[uuid];
      if (data == null || data.length < 13) continue;

      final parsed = _parseScale(data);
      if (parsed == null || !parsed['stabilized']) continue;

      // Dedup on scale's own timestamp + measurement (scale broadcasts the
      // same advertisement repeatedly until you step off)
      final key = '${parsed['scale_ts']}-${parsed['weight']}-${parsed['impedance']}';
      if (key == _lastSeenKey) continue;
      _lastSeenKey = key;

      // Use the phone's wall clock as the real measurement time. The scale's
      // RTC is unreliable (often UTC even when set to local via Mi Fit), so
      // trusting it leads to wrong dates in Garmin. The advertisement arrives
      // within seconds of stepping on the scale, so "now" is accurate enough.
      parsed['timestamp'] = DateTime.now().toUtc().toIso8601String();

      if (!completer.isCompleted) completer.complete();

      _handleMeasurement(service, notifications, parsed);
    }
  });

  await Future.any([completer.future, Future.delayed(const Duration(seconds: 30))]);
  await sub.cancel();
  await FlutterBluePlus.stopScan();
  print('[Scale] Scan ended');
}

void _handleMeasurement(
  ServiceInstance service,
  FlutterLocalNotificationsPlugin notifications,
  Map<String, dynamic> parsed,
) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (now - _lastUploadTime < _cooldownSeconds) return;

  final storage = const FlutterSecureStorage();
  final height = double.tryParse(await storage.read(key: 'height') ?? '175') ?? 175;
  final age    = int.tryParse(await storage.read(key: 'age') ?? '30') ?? 30;
  final sex    = await storage.read(key: 'sex') ?? 'male';

  Map<String, dynamic> comp = {};
  if (parsed['has_impedance'] == true) {
    comp = _bodyComposition(
      weight: parsed['weight'],
      impedance: parsed['impedance'],
      height: height,
      age: age,
      sex: sex,
    );
  }

  // Send to UI
  service.invoke('measurement', {...parsed, ...comp});

  // Upload to Garmin
  final token = await storage.read(key: 'garmin_access_token') ?? '';
  if (token.isEmpty) {
    _notify(notifications, 'Scale detected', 'Open the app → Settings → Login to Garmin to enable upload.');
    return;
  }

  try {
    final client = GarminClient(token);
    await client.uploadBodyComposition(
      timestamp: DateTime.parse(parsed['timestamp']),
      weight:    (parsed['weight'] as num).toDouble(),
      height:    height,
      percentFat:       (comp['fat_pct'] as num?)?.toDouble(),
      percentHydration: (comp['water_pct'] as num?)?.toDouble(),
      muscleKg:         (comp['muscle_kg'] as num?)?.toDouble(),
    );
    _lastUploadTime = now;

    final msg = comp.isEmpty
        ? '${parsed['weight'].toStringAsFixed(1)} kg uploaded'
        : '${parsed['weight'].toStringAsFixed(1)} kg · ${comp['fat_pct']}% fat · ${comp['muscle_kg']} kg muscle';
    _notify(notifications, 'Garmin updated ✓', msg);
  } catch (e) {
    _notify(notifications, 'Upload failed', e.toString());
  }
}

void _notify(FlutterLocalNotificationsPlugin n, String title, String body) {
  n.show(
    1,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'scale_results',
        'Scale Results',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

Map<String, dynamic>? _parseScale(List<int> data) {
  if (data.length < 13) return null;

  final ctrl1     = data[1];
  final year      = data[2] | (data[3] << 8);
  final month     = data[4];
  final day       = data[5];
  final hour      = data[6];
  final minute    = data[7];
  final second    = data[8];
  final impedance = data[9] | (data[10] << 8);
  final rawWeight = data[11] | (data[12] << 8);

  final double weight;
  final String unit;
  if (ctrl1 & 0x10 != 0) {
    weight = rawWeight / 100; unit = 'jin';
  } else if (ctrl1 & 0x01 != 0) {
    weight = rawWeight / 100; unit = 'lbs';
  } else {
    weight = rawWeight / 200; unit = 'kg';
  }

  final stabilized   = (ctrl1 & 0x20) != 0;
  final hasImpedance = (ctrl1 & 0x02) != 0;
  // Scale's own timestamp — used only for deduplication, not for display/upload
  final scaleTs = '$year-$month-$day-$hour-$minute-$second';

  return {
    'scale_ts':      scaleTs,
    'weight':        weight,
    'unit':          unit,
    'impedance':     hasImpedance ? impedance : null,
    'stabilized':    stabilized,
    'has_impedance': hasImpedance,
  };
}

Map<String, dynamic> _bodyComposition({
  required double weight,
  required int impedance,
  required double height,
  required int age,
  required String sex,
}) {
  final h = height / 100;
  double lbm = (height * 9.058 / 100) * h + weight * 0.32 + 12.226;
  lbm -= impedance * 0.0068 + age * 0.0542;

  double fatPct;
  if (sex == 'male') {
    final coeff = age <= 30 ? 0.9462 : (age <= 45 ? 0.9 : 1.0);
    fatPct = (1 - ((lbm - 0.8 + lbm * coeff * 0.05) / weight)) * 100;
    fatPct = fatPct.clamp(5.0, 75.0);
  } else {
    fatPct = (1 - ((lbm - 0.8 + lbm * 0.05) / weight)) * 100;
    fatPct = fatPct.clamp(10.0, 75.0);
  }

  final muscleKg = weight - (weight * fatPct / 100);
  final waterPct = (muscleKg / weight) * 73.0;
  final bmi      = weight / (h * h);

  return {
    'fat_pct':   double.parse(fatPct.toStringAsFixed(1)),
    'muscle_kg': double.parse(muscleKg.toStringAsFixed(1)),
    'water_pct': double.parse(waterPct.toStringAsFixed(1)),
    'bmi':       double.parse(bmi.toStringAsFixed(1)),
  };
}
