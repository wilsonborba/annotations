/// Compact stroke samples (annotations#19, the same format as the backend
/// `stroke_samples.rs`): `{"count": n, "data": "<base64url>"}`.
///
/// `data` is base64url without padding of: byte 0, the format version 1;
/// byte 1, flags (bit 0 a pressure column, bit 1 a tilt column); then the
/// columns x, y, t, and pressure and tilt when flagged, `count` values each.
/// Every value is the zigzag-encoded difference to the value before it in
/// its column (the first one to 0), as an unsigned LEB128 varint. Units: x
/// and y in 1/100 page units, t in ms from the stroke start, pressure 0 to
/// 1000, tilt in milliradians.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The decoded columns. [pressure] and [tilt] are absent or as long as [x].
final class SampleColumns {
  const SampleColumns({
    required this.x,
    required this.y,
    required this.t,
    this.pressure,
    this.tilt,
  });
  final List<int> x, y, t;
  final List<int>? pressure, tilt;

  int get length => x.length;
}

/// Data that cannot be read: not base64url, another version, unknown flags,
/// or the wrong length for its count.
final class MalformedSamples implements Exception {
  const MalformedSamples();
}

abstract final class SampleCodec {
  static const version = 1;
  static const _pressure = 1, _tilt = 2;

  /// The stored JSON of [c].
  static Map<String, Object?> encode(SampleColumns c) {
    final out = BytesBuilder(copy: false)
      ..addByte(version)
      ..addByte(
        (c.pressure != null ? _pressure : 0) | (c.tilt != null ? _tilt : 0),
      );
    void column(List<int> values) {
      var last = 0;
      for (final v in values) {
        var z = _zigzag(v - last);
        last = v;
        while (z >= 0x80) {
          out.addByte((z & 0x7f) | 0x80);
          z >>= 7;
        }
        out.addByte(z);
      }
    }

    column(c.x);
    column(c.y);
    column(c.t);
    if (c.pressure case final p?) column(p);
    if (c.tilt case final t?) column(t);
    return {
      'count': c.length,
      'data': base64Url.encode(out.takeBytes()).replaceAll('=', ''),
    };
  }

  /// The columns of a stored `samples` object.
  static SampleColumns decodeJson(Map samples) {
    final count = samples['count'], data = samples['data'];
    if (count is! int || data is! String) throw const MalformedSamples();
    return decode(count, data);
  }

  static SampleColumns decode(int count, String data) {
    final Uint8List bytes;
    try {
      if (data.contains('=')) throw const FormatException();
      bytes = base64Url.decode(base64Url.normalize(data));
    } on FormatException {
      throw const MalformedSamples();
    }
    if (count < 0 ||
        bytes.length < 2 ||
        bytes[0] != version ||
        bytes[1] & ~(_pressure | _tilt) != 0) {
      throw const MalformedSamples();
    }
    final flags = bytes[1];
    var at = 2;
    List<int> column() {
      final values = List<int>.filled(count, 0);
      var last = 0;
      for (var i = 0; i < count; i++) {
        var v = 0, shift = 0;
        while (true) {
          if (at >= bytes.length || shift > 56) throw const MalformedSamples();
          final b = bytes[at++];
          v |= (b & 0x7f) << shift;
          if (b & 0x80 == 0) break;
          shift += 7;
        }
        last += _unzigzag(v);
        values[i] = last;
      }
      return values;
    }

    final x = column(), y = column(), t = column();
    final pressure = flags & _pressure != 0 ? column() : null;
    final tilt = flags & _tilt != 0 ? column() : null;
    if (at != bytes.length) throw const MalformedSamples();
    return SampleColumns(x: x, y: y, t: t, pressure: pressure, tilt: tilt);
  }

  static int _zigzag(int v) => v >= 0 ? v << 1 : ((-v) << 1) - 1;
  static int _unzigzag(int v) => v.isEven ? v >> 1 : -((v + 1) >> 1);
}
