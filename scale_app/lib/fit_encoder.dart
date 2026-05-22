import 'dart:typed_data';

class FitEncoder {
  final _body = BytesBuilder();

  // FIT protocol epoch: 1989-12-31 00:00:00 UTC
  static final _epoch = DateTime.utc(1989, 12, 31);

  int _ts(DateTime dt) => dt.toUtc().difference(_epoch).inSeconds;

  void _u8(int v) => _body.addByte(v & 0xFF);
  void _u16(int v) { _body.addByte(v & 0xFF); _body.addByte((v >> 8) & 0xFF); }
  void _u32(int v) { _body.addByte(v & 0xFF); _body.addByte((v >> 8) & 0xFF); _body.addByte((v >> 16) & 0xFF); _body.addByte((v >> 24) & 0xFF); }

  static const _invalid16 = 0xFFFF;
  int _scale(double? v, double s) => v != null ? (v * s).round().clamp(0, 0xFFFE) : _invalid16;

  void _def(int local, int global, List<(int, int, int)> fields) {
    _u8(0x40 | local); _u8(0); _u8(0); _u16(global); _u8(fields.length);
    for (final (n, sz, t) in fields) { _u8(n); _u8(sz); _u8(t); }
  }

  void writeFileId(DateTime dt) {
    _def(0, 0, [(0,1,0x00),(1,2,0x84),(2,2,0x84),(3,4,0x8C),(4,4,0x86)]);
    _u8(0); _u8(9); _u16(1); _u16(0); _u32(0); _u32(_ts(dt));
  }

  void writeFileCreator() {
    _def(1, 49, [(0,2,0x84),(1,1,0x02)]);
    _u8(1); _u16(0); _u8(0xFF);
  }

  void writeDeviceInfo(DateTime dt) {
    _def(2, 23, [(253,4,0x86),(0,1,0x02),(1,1,0x02),(2,2,0x84),(4,2,0x84)]);
    _u8(2); _u32(_ts(dt)); _u8(0); _u8(0xFF); _u16(1); _u16(0);
  }

  void writeWeightScale({
    required DateTime dt,
    required double weight,
    double? percentFat,
    double? percentHydration,
    double? muscleKg,
    double? boneKg,
    double? bmi,
  }) {
    _def(3, 30, [
      (253,4,0x86),(0,2,0x84),(1,2,0x84),
      (2,2,0x84),(4,2,0x84),(5,2,0x84),(15,2,0x84),
    ]);
    _u8(3);
    _u32(_ts(dt));
    _u16((weight * 100).round());
    _u16(_scale(percentFat, 100));
    _u16(_scale(percentHydration, 100));
    _u16(_scale(boneKg, 100));
    _u16(_scale(muscleKg, 100));
    _u16(_scale(bmi, 10));
  }

  Uint8List encode() {
    final body = Uint8List.fromList(_body.toBytes());

    final hd = ByteData(12);
    hd.setUint8(0, 14);
    hd.setUint8(1, 0x20);
    hd.setUint16(2, 2054, Endian.little);
    hd.setUint32(4, body.length, Endian.little);
    for (final (i, c) in [(8, 0x2E),(9, 0x46),(10, 0x49),(11, 0x54)]) {
      hd.setUint8(i, c);
    }

    final headerBytes = hd.buffer.asUint8List();
    final headerCrc = _crc(headerBytes, 0, 12);
    final bodyCrc   = _crc(body, 0, body.length);

    final out = BytesBuilder()
      ..add(headerBytes)
      ..addByte(headerCrc & 0xFF)
      ..addByte((headerCrc >> 8) & 0xFF)
      ..add(body)
      ..addByte(bodyCrc & 0xFF)
      ..addByte((bodyCrc >> 8) & 0xFF);

    return out.toBytes();
  }

  int _crc(List<int> data, int start, int end) {
    const t = [
      0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
      0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ];
    int crc = 0;
    for (int i = start; i < end; i++) {
      int tmp = t[crc & 0x0F]; crc = (crc >> 4) & 0x0FFF; crc ^= tmp ^ t[data[i] & 0x0F];
          tmp = t[crc & 0x0F]; crc = (crc >> 4) & 0x0FFF; crc ^= tmp ^ t[(data[i] >> 4) & 0x0F];
    }
    return crc;
  }
}
