import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

/// Live BLE event feed for debugging scale reception.
///
/// Shows every parsed packet from the background service — including
/// unstabilized readings — so you can see what the scale is actually
/// broadcasting in real time.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});
  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  final _events = <_BleEvent>[];
  StreamSubscription<Map<String, dynamic>?>? _sub;
  static const _maxEvents = 100;

  @override
  void initState() {
    super.initState();
    _sub = FlutterBackgroundService().on('ble_event').listen((data) {
      if (data == null) return;
      final event = _BleEvent.fromMap(data);
      if (mounted) {
        setState(() {
          _events.insert(0, event);
          if (_events.length > _maxEvents) _events.removeLast();
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live BLE events'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear',
            onPressed: () => setState(() => _events.clear()),
          ),
        ],
      ),
      body: _events.isEmpty
          ? const Center(
              child: Text(
                'No BLE packets yet.\nStart the service and step on the scale.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: _events.length,
              itemBuilder: (_, i) => _EventTile(event: _events[i]),
            ),
    );
  }
}

class _BleEvent {
  final DateTime ts;
  final double weight;
  final String unit;
  final int? impedance;
  final bool stabilized;
  final bool hasImpedance;

  _BleEvent({
    required this.ts,
    required this.weight,
    required this.unit,
    required this.impedance,
    required this.stabilized,
    required this.hasImpedance,
  });

  factory _BleEvent.fromMap(Map<String, dynamic> m) => _BleEvent(
    ts:           DateTime.parse(m['ts'] as String).toLocal(),
    weight:       (m['weight'] as num).toDouble(),
    unit:         m['unit'] as String,
    impedance:    m['impedance'] as int?,
    stabilized:   m['stabilized'] as bool,
    hasImpedance: m['has_impedance'] as bool,
  );
}

class _EventTile extends StatelessWidget {
  final _BleEvent event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    String pad(int n) => n.toString().padLeft(2, '0');
    final t = event.ts;
    final timeStr = '${pad(t.hour)}:${pad(t.minute)}:${pad(t.second)}';

    final stable = event.stabilized;
    final imp = event.hasImpedance ? 'imp ${event.impedance}' : 'no impedance';

    return ListTile(
      dense: true,
      leading: Icon(
        stable ? Icons.check_circle : Icons.radio_button_unchecked,
        color: stable ? Colors.green : Colors.grey,
        size: 20,
      ),
      title: Text(
        '${event.weight.toStringAsFixed(2)} ${event.unit}  ·  $imp',
        style: TextStyle(
          fontWeight: stable ? FontWeight.bold : FontWeight.normal,
          color: stable ? null : Colors.grey,
        ),
      ),
      subtitle: Text(timeStr, style: const TextStyle(fontSize: 11)),
      trailing: stable
          ? const Text('STABLE', style: TextStyle(color: Colors.green, fontSize: 11))
          : const Text('...', style: TextStyle(color: Colors.grey, fontSize: 11)),
    );
  }
}
