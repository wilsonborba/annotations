// Note capacity (annotations#19): dense handwriting captured with the real
// editor capture code (StrokeCapture, node fitting) and the stored sizes.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:flutter_test/flutter_test.dart';

const pen = BrushSettings(tool: InkTool.round, width: 3, color: '#000000FF');

/// One handwritten stroke at 240 Hz: a pen path of a small letter group with
/// loops, natural speed changes, pressure and tilt from a stylus.
Map<String, Object?> handwriting(int i, {int hz = 240, double seconds = 0.35}) {
  final rnd = math.Random(i);
  final capture = StrokeCapture(pen, pageWidth: 1000);
  final x0 = 40.0 + (i % 40) * 23.0, y0 = 60.0 + (i ~/ 40) * 36.0;
  final n = (hz * seconds).round();
  final loops = 1 + rnd.nextInt(3), size = 6 + rnd.nextDouble() * 6;
  for (var k = 0; k < n; k++) {
    final a = k / (n - 1);
    final s = a - 0.08 * math.sin(a * math.pi * 2); // uneven speed
    final x = x0 + s * 18 + math.sin(s * math.pi * 2 * loops) * size * 0.35;
    final y =
        y0 +
        math.cos(s * math.pi * 2 * loops) * size * 0.5 +
        math.sin(s * 9.1 + i) * 1.2;
    capture.add(
      x,
      y,
      1000 + (k * 1000 / hz).round(),
      pressure: 0.35 + 0.4 * math.sin(a * math.pi) + rnd.nextDouble() * 0.03,
      tilt: 0.6 + 0.15 * a,
    );
  }
  return capture.toItem('s$i')!;
}

Map<String, Object?> page(int strokes, {int from = 0}) => {
  'page': {
    'width': 1000,
    'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.4},
  },
  'items': [for (var i = 0; i < strokes; i++) handwriting(from + i)],
};

void main() {
  test('dense handwriting sizes from the editor capture', () {
    final stroke = handwriting(7);
    final bytes = utf8.encode(jsonEncode(stroke)).length;
    final samples = utf8.encode(jsonEncode(stroke['samples'])).length;
    final nodes = utf8.encode(jsonEncode(stroke['nodes'])).length;
    final nodeCount = (stroke['nodes'] as List).length;
    final one = utf8.encode(jsonEncode(page(800)));
    final gz = gzip.encode(one).length;
    final report =
        'stroke: $bytes bytes (samples $samples, nodes $nodes, $nodeCount nodes); '
        'dense page 800 strokes: ${one.length} bytes JSON, $gz bytes gzip; '
        '30 pages: ${one.length * 30} bytes JSON, ${gz * 30} bytes gzip';
    // ignore: avoid_print
    print(report);
    expect(nodeCount, greaterThan(1));
  });

  test('a 30-page note through the editor model and rules', () {
    final items = <Object?>[];
    for (var p = 0; p < 30; p++) {
      items.addAll(page(800, from: p * 800)['items'] as List);
    }
    final json = {
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    };
    final watch = Stopwatch()..start();
    final text = jsonEncode(json);
    final encode = watch.elapsedMilliseconds;
    watch.reset();
    final doc = NoteDocument.fromJson(
      jsonDecode(text) as Map<String, Object?>,
      schema: DocumentSchema('note-original', 1),
    );
    final parse = watch.elapsedMilliseconds;
    watch.reset();
    const rules = EditorRules(
      limits: NoteLimits(maxItems: 100000, maxDocumentBytes: 1 << 30),
    );
    final d = rules.check(doc, {'op': 'add', 'item': handwriting(999999)});
    final check = watch.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      '30 pages: ${text.length} bytes, ${items.length} strokes; encode $encode ms, parse $parse ms, one stroke edit check $check ms (${d.error})',
    );
  });
}
