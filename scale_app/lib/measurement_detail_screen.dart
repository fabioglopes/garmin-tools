import 'package:flutter/material.dart';
import 'calibration.dart';
import 'models.dart';
import 'store.dart';

class MeasurementDetailScreen extends StatefulWidget {
  final Measurement measurement;
  final Profile? profile;
  const MeasurementDetailScreen({
    super.key,
    required this.measurement,
    required this.profile,
  });

  @override
  State<MeasurementDetailScreen> createState() => _MeasurementDetailScreenState();
}

class _MeasurementDetailScreenState extends State<MeasurementDetailScreen> {
  final _refFat    = TextEditingController();
  final _refMuscle = TextEditingController();
  final _refWater  = TextEditingController();

  CalibratedValues? _calibrated;
  int _referenceCount = 0;
  bool _saving = false;

  late Measurement _m;

  @override
  void initState() {
    super.initState();
    _m = widget.measurement;
    _refFat.text    = _m.refFatPct   != null ? _m.refFatPct!.toStringAsFixed(1)   : '';
    _refMuscle.text = _m.refMuscleKg != null ? _m.refMuscleKg!.toStringAsFixed(1) : '';
    _refWater.text  = _m.refWaterPct != null ? _m.refWaterPct!.toStringAsFixed(1)  : '';
    _loadCalibration();
  }

  Future<void> _loadCalibration() async {
    if (widget.profile == null || _m.fatPct == null) return;
    final all = await Store.loadMeasurements();
    final forProfile = all.where((x) => x.profileId == widget.profile!.id).toList();
    final refCount = forProfile
        .where((x) => x.id != _m.id && (x.refFatPct != null || x.refMuscleKg != null))
        .length;
    final cal = computeCalibration(_m, forProfile);
    if (mounted) {
      setState(() {
        _calibrated = cal;
        _referenceCount = refCount;
      });
    }
  }

  Future<void> _save() async {
    final fat    = double.tryParse(_refFat.text.trim());
    final muscle = double.tryParse(_refMuscle.text.trim());
    final water  = double.tryParse(_refWater.text.trim());

    if (_refFat.text.trim().isNotEmpty    && fat    == null ||
        _refMuscle.text.trim().isNotEmpty && muscle == null ||
        _refWater.text.trim().isNotEmpty  && water  == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reference values must be numbers.')),
      );
      return;
    }

    setState(() => _saving = true);
    _m.refFatPct   = fat;
    _m.refMuscleKg = muscle;
    _m.refWaterPct = water;
    await Store.updateMeasurement(_m);
    await _loadCalibration();
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reference values saved.')),
      );
    }
  }

  @override
  void dispose() {
    _refFat.dispose();
    _refMuscle.dispose();
    _refWater.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dt = _m.timestamp.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    final dateStr =
        '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';

    final hasBodyComp = _m.fatPct != null;
    final hasCal      = _calibrated != null && _calibrated!.hasAny;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile?.name ?? 'Measurement'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Basic info ─────────────────────────────────────────────────
          _Section('Measurement'),
          _Row('Date', dateStr),
          _Row('Weight', '${_m.weight.toStringAsFixed(2)} ${_m.unit}'),
          if (_m.impedance != null) _Row('Impedance', '${_m.impedance} Ω'),
          _Row('Profile', widget.profile?.name ?? 'Unassigned'),

          // ── Body composition ────────────────────────────────────────────
          if (hasBodyComp) ...[
            const SizedBox(height: 20),
            if (hasCal) ...[
              _Section('Body Composition'),
              const SizedBox(height: 4),
              Text(
                _refModelLabel(),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              _CompTable(m: _m, calibrated: _calibrated),
            ] else ...[
              _Section('Body Composition (raw from scale)'),
              _Row('Fat',    '${_m.fatPct} %'),
              _Row('Muscle', '${_m.muscleKg} kg'),
              _Row('Water',  '${_m.waterPct} %'),
              _Row('BMI',    '${_m.bmi}'),
            ],
          ],

          // ── Sync status ──────────────────────────────────────────────────
          const SizedBox(height: 20),
          _Section('Sync status'),
          if (_m.synced && _m.syncedAt != null)
            _Row('Garmin', 'Synced ✓ ${pad(_m.syncedAt!.toLocal().hour)}:${pad(_m.syncedAt!.toLocal().minute)}')
          else if (_m.syncError != null)
            _Row('Garmin', 'Failed: ${_m.syncError}', valueColor: Colors.red)
          else if (widget.profile == null)
            _Row('Garmin', 'Unassigned')
          else if (!widget.profile!.hasGarmin)
            _Row('Garmin', 'App-only profile')
          else
            _Row('Garmin', 'Not synced'),

          // ── Reference values ─────────────────────────────────────────────
          if (hasBodyComp) ...[
            const SizedBox(height: 24),
            _Section('Reference values (e.g. from Tanita)'),
            const SizedBox(height: 4),
            const Text(
              'Enter your reference device\'s readings for this weigh-in. '
              'These are used to calibrate all future measurements for this profile.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _RefField(controller: _refFat,    label: 'Fat %',     hint: 'e.g. 22.0'),
            const SizedBox(height: 8),
            _RefField(controller: _refMuscle, label: 'Muscle kg', hint: 'e.g. 59.0'),
            const SizedBox(height: 8),
            _RefField(controller: _refWater,  label: 'Water %',   hint: 'e.g. 57.0'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save reference values'),
            ),
          ],
        ],
      ),
    );
  }

  String _refModelLabel() {
    if (_m.refFatPct != null || _m.refMuscleKg != null) {
      return 'Corrected = reference values entered for this measurement';
    }
    if (_referenceCount == 0) return 'No calibration data yet';
    final method = _referenceCount >= 3 ? 'linear fit' : 'offset';
    return 'Corrected via $method ($_referenceCount reference point${_referenceCount == 1 ? "" : "s"})';
  }
}

// ── Helper widgets ─────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  const _Section(this.title);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Row(this.label, this.value, {this.valueColor});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 100, child: Text(label, style: const TextStyle(color: Colors.grey))),
        Expanded(child: Text(value, style: TextStyle(color: valueColor))),
      ],
    ),
  );
}

class _CompTable extends StatelessWidget {
  final Measurement m;
  final CalibratedValues? calibrated;
  const _CompTable({required this.m, required this.calibrated});

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(2),
      },
      children: [
        _header(),
        _dataRow('Fat %',    m.fatPct,   calibrated?.fatPct,   '%'),
        _dataRow('Muscle kg', m.muscleKg, calibrated?.muscleKg, 'kg'),
        _dataRow('Water %',  m.waterPct, calibrated?.waterPct, '%'),
        _dataRow('BMI',      m.bmi,      null,                 ''),
      ],
    );
  }

  TableRow _header() => TableRow(
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey))),
    children: [
      _cell('Metric',    bold: true),
      _cell('Raw',       bold: true),
      _cell('Corrected', bold: true, color: Colors.blue),
    ],
  );

  TableRow _dataRow(String label, double? raw, double? corrected, String unit) => TableRow(
    children: [
      _cell(label),
      _cell(raw    != null ? '$raw $unit'.trim() : '—'),
      _cell(corrected != null ? '$corrected $unit'.trim() : '—', color: Colors.blue),
    ],
  );

  Widget _cell(String text, {bool bold = false, Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      style: TextStyle(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        color: color,
      ),
    ),
  );
}

class _RefField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  const _RefField({required this.controller, required this.label, required this.hint});
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  );
}
