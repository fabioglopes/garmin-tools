import 'dart:async';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'body_composition.dart';
import 'models.dart';
import 'profile_matcher.dart';
import 'scale_parser.dart';
import 'store.dart';
import 'uploader.dart';

const _scaleUuid = '0000181b-0000-1000-8000-00805f9b34fb';

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

  FlutterBluePlus.setLogLevel(LogLevel.error);
  await FlutterBluePlus.adapterState
      .where((s) => s == BluetoothAdapterState.on)
      .first
      .timeout(const Duration(seconds: 15), onTimeout: () => BluetoothAdapterState.unknown);

  final btState = await FlutterBluePlus.adapterState.first;
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

  // Buffer: collect the best stabilized packet for a short window after the
  // first stable reading arrives. The Xiaomi scale emits weight-only packets
  // first and adds impedance a second or two later — buffering lets us wait
  // for the complete reading instead of saving a body-comp-free record.
  Map<String, dynamic>? bestParsed;
  DateTime? bestTimestamp;

  try {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));
  } catch (e) {
    print('[Scale] startScan error: $e');
    return;
  }

  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final result in results) {
      final uuid = Guid(_scaleUuid);
      final data = result.advertisementData.serviceData[uuid];
      if (data == null || data.length < 13) continue;

      final parsed = parseScale(data);
      if (parsed == null) continue;

      // Emit every parsed packet to the debug screen (including unstabilized).
      service.invoke('ble_event', {
        'ts':            DateTime.now().toUtc().toIso8601String(),
        'weight':        parsed['weight'],
        'unit':          parsed['unit'],
        'impedance':     parsed['impedance'],
        'stabilized':    parsed['stabilized'],
        'has_impedance': parsed['has_impedance'],
      });

      if (!parsed['stabilized']) continue;

      final isFirst     = bestParsed == null;
      final newHasImp   = parsed['has_impedance'] == true;
      final bestHasImp  = bestParsed?['has_impedance'] == true;
      // Only upgrade if weight is close — guards against a second person
      // stepping on the scale during the buffer window.
      final sameWeighIn = bestParsed == null ||
          ((parsed['weight'] as num) - (bestParsed!['weight'] as num)).abs() < 0.5;

      if (bestParsed == null || (newHasImp && !bestHasImp && sameWeighIn)) {
        bestParsed   = parsed;
        bestTimestamp = DateTime.now().toUtc();
      }

      // On the first stabilized packet open a 5-second collection window.
      // Any subsequent packet with impedance will upgrade bestParsed above.
      // After 5 s we commit whichever packet is best.
      if (isFirst) {
        // Notify the UI immediately so the measurement appears in the list
        // right away, even before body-comp data is available.
        service.invoke('pending_measurement', {
          'weight': parsed['weight'],
          'unit':   parsed['unit'],
        });

        Future.delayed(const Duration(seconds: 5), () {
          final best = bestParsed;
          final ts   = bestTimestamp;
          if (best != null && ts != null) {
            final key = '${best['scale_ts']}-${best['weight']}-${best['impedance']}';
            if (key != _lastSeenKey) {
              _lastSeenKey = key;
              _handleMeasurement(service, notifications, best, ts);
            }
          }
          if (!completer.isCompleted) completer.complete();
        });
      }
    }
  });

  await Future.any([completer.future, Future.delayed(const Duration(seconds: 30))]);
  await sub.cancel();
  await FlutterBluePlus.stopScan();
}

Future<void> _handleMeasurement(
  ServiceInstance service,
  FlutterLocalNotificationsPlugin notifications,
  Map<String, dynamic> parsed,
  DateTime timestamp,
) async {
  final weight = (parsed['weight'] as num).toDouble();
  final profiles = await Store.loadProfiles();
  final match = matchProfile(weight, profiles);

  final measurement = Measurement(
    id: timestamp.microsecondsSinceEpoch.toString(),
    profileId: match?.id,
    timestamp: timestamp,
    weight: weight,
    unit: parsed['unit'] as String,
    impedance: parsed['impedance'] as int?,
  );

  // Body composition needs a profile (for height/age/sex)
  Measurement enriched = measurement;
  if (match != null && parsed['has_impedance'] == true) {
    final comp = bodyComposition(
      weight: weight,
      impedance: parsed['impedance'] as int,
      height: match.height,
      age: match.ageOn(timestamp),
      sex: match.sex,
    );
    enriched = Measurement(
      id: measurement.id,
      profileId: measurement.profileId,
      timestamp: measurement.timestamp,
      weight: measurement.weight,
      unit: measurement.unit,
      impedance: measurement.impedance,
      fatPct:   comp['fat_pct'],
      muscleKg: comp['muscle_kg'],
      waterPct: comp['water_pct'],
      bmi:      comp['bmi'],
    );
  }

  // Dedup against recent measurements before persisting — the scale
  // rebroadcasts for ~5 min after a weigh-in. Include soft-deleted entries
  // so a deletion in the UI doesn't let the next replay re-create the record.
  final existing = await Store.loadMeasurements(includeDeleted: true);
  if (isDuplicateMeasurement(enriched, existing)) {
    return;
  }

  await Store.appendMeasurement(enriched);
  service.invoke('measurement', enriched.toJson());

  if (match != null) {
    await _updateExpectedWeight(profiles, match, weight);
    await _uploadIfPossible(notifications, match, enriched);
  } else {
    await _notifyUnassigned(notifications, enriched, profiles);
  }
}

Future<void> _updateExpectedWeight(List<Profile> all, Profile match, double weight) async {
  match.expectedWeight = weight;
  await Store.saveProfiles(all);
}

Future<void> _uploadIfPossible(
  FlutterLocalNotificationsPlugin notifications,
  Profile profile,
  Measurement m,
) async {
  if (!profile.hasGarmin) return;
  try {
    await uploadMeasurement(profile, m);
    final msg = m.fatPct == null
        ? '${m.weight.toStringAsFixed(1)} kg uploaded'
        : '${m.weight.toStringAsFixed(1)} kg · ${m.fatPct}% fat · ${m.muscleKg} kg muscle';
    _notify(notifications, '${profile.name} → Garmin ✓', msg);
  } catch (e) {
    _notify(notifications, 'Upload failed (${profile.name})', e.toString());
  }
}

Future<void> _notifyUnassigned(
  FlutterLocalNotificationsPlugin notifications,
  Measurement m,
  List<Profile> profiles,
) async {
  // Android caps action buttons at 3. Show up to two profiles + "Skip".
  final picks = profiles.take(2).toList();
  final actions = <AndroidNotificationAction>[
    for (final p in picks)
      AndroidNotificationAction('pid:${p.id}', p.name, showsUserInterface: false),
    const AndroidNotificationAction('skip', 'Skip', showsUserInterface: false),
  ];

  final body = profiles.isEmpty
      ? '${m.weight.toStringAsFixed(1)} kg — no profiles yet. Open app to add one.'
      : '${m.weight.toStringAsFixed(1)} kg — no profile matched. Pick one:';

  await notifications.show(
    2,
    'Unassigned measurement',
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        'scale_results',
        'Scale Results',
        importance: Importance.high,
        priority: Priority.high,
        actions: actions,
      ),
    ),
    payload: 'assign:${m.id}',
  );
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

/// Background handler for notification action taps. Called by the OS in a
/// separate isolate, so it needs the `vm:entry-point` pragma and cannot
/// rely on shared in-memory state.
@pragma('vm:entry-point')
void onNotificationAction(NotificationResponse response) async {
  final actionId = response.actionId;
  final payload  = response.payload;
  if (payload == null || !payload.startsWith('assign:')) return;
  final mId = payload.substring('assign:'.length);

  if (actionId == 'skip' || actionId == null) return;
  if (!actionId.startsWith('pid:')) return;
  final pid = actionId.substring('pid:'.length);

  final all = await Store.loadMeasurements();
  final i = all.indexWhere((m) => m.id == mId);
  if (i == -1) return;
  final m = all[i];
  m.profileId = pid;

  final profiles = await Store.loadProfiles();
  final profile  = profiles.firstWhere((p) => p.id == pid, orElse: () => throw StateError('profile $pid not found'));

  // Recompute body composition with chosen profile's body data, if impedance was captured
  if (m.impedance != null) {
    final comp = bodyComposition(
      weight: m.weight,
      impedance: m.impedance!,
      height: profile.height,
      age: profile.ageOn(m.timestamp),
      sex: profile.sex,
    );
    final m2 = Measurement(
      id: m.id, profileId: pid, timestamp: m.timestamp, weight: m.weight,
      unit: m.unit, impedance: m.impedance,
      fatPct: comp['fat_pct'], muscleKg: comp['muscle_kg'],
      waterPct: comp['water_pct'], bmi: comp['bmi'],
    );
    all[i] = m2;
    await Store.saveMeasurements(all);
    profile.expectedWeight = m.weight;
    await Store.saveProfiles(profiles);

    final notif = FlutterLocalNotificationsPlugin();
    await notif.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await _uploadIfPossible(notif, profile, m2);
  } else {
    await Store.saveMeasurements(all);
    profile.expectedWeight = m.weight;
    await Store.saveProfiles(profiles);
  }
}
