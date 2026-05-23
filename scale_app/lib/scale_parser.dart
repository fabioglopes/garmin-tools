/// Parse a Xiaomi/PICOOC scale BLE service-data payload (service UUID 0x181b).
///
/// Returns null if the payload is too short. The `stabilized` flag indicates
/// the user is standing still on the scale; only stabilized readings should be
/// used. `has_impedance` is true only when the user is barefoot on the
/// electrodes — without it, body composition cannot be computed.
Map<String, dynamic>? parseScale(List<int> data) {
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
