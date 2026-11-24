// Rasterizes one PDF page with poppler (pdftoppm) at 72 dpi, so one pixel is
// one PDF point, to check where vector ink actually lands (annotations#42).
import 'dart:io';
import 'dart:typed_data';

final class PdfRaster {
  PdfRaster._(this.width, this.height, this._rgb);
  final int width, height;
  final Uint8List _rgb;

  static Future<PdfRaster> page(Uint8List pdf, {int page = 1}) async {
    final dir = await Directory.systemTemp.createTemp('pdf_raster_');
    try {
      final file = File('${dir.path}/in.pdf')..writeAsBytesSync(pdf);
      final res = await Process.run('pdftoppm', [
        '-r',
        '72',
        '-f',
        '$page',
        '-l',
        '$page',
        '-singlefile',
        file.path,
        '${dir.path}/out',
      ]);
      if (res.exitCode != 0) throw StateError('pdftoppm: ${res.stderr}');
      return _parsePpm(File('${dir.path}/out.ppm').readAsBytesSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  static PdfRaster _parsePpm(Uint8List b) {
    var i = 0;
    String token() {
      while (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
        i++;
      }
      final s = i;
      while (b[i] != 0x20 && b[i] != 0x0A && b[i] != 0x0D && b[i] != 0x09) {
        i++;
      }
      return String.fromCharCodes(b.sublist(s, i));
    }

    if (token() != 'P6') throw const FormatException('not a P6 ppm');
    final w = int.parse(token()), h = int.parse(token());
    token(); // max value
    i++;
    return PdfRaster._(w, h, b.sublist(i, i + w * h * 3));
  }

  (int, int, int) at(int x, int y) {
    final o = (y * width + x) * 3;
    return (_rgb[o], _rgb[o + 1], _rgb[o + 2]);
  }

  /// The bounding box (left, top, right, bottom) of the pixels for which
  /// [match] holds, or null when none does.
  (int, int, int, int)? box(bool Function(int r, int g, int b) match) {
    int? l, t, r, bt;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final (cr, cg, cb) = at(x, y);
        if (!match(cr, cg, cb)) continue;
        l = l == null || x < l ? x : l;
        r = r == null || x > r ? x : r;
        t ??= y;
        bt = y;
      }
    }
    return l == null ? null : (l, t!, r!, bt!);
  }

  int count(bool Function(int r, int g, int b) match) {
    var n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final (cr, cg, cb) = at(x, y);
        if (match(cr, cg, cb)) n++;
      }
    }
    return n;
  }
}

/// Clearly red ink (stroke color #DC2626 or pure red), not black text.
bool isRed(int r, int g, int b) => r > 150 && g < 110 && b < 110;

/// A light red fill such as #FEE2E2 at half alpha on white.
bool isPinkFill(int r, int g, int b) =>
    r > 240 && g > 220 && g < 250 && b > 220 && b < 250 && r - g > 4;
