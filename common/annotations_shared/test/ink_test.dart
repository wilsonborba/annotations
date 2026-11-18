import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:annotations_shared/core/ink_settings.dart';
import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/ink_eraser.dart';
import 'package:annotations_shared/domain/services/ink_geometry.dart';
import 'package:annotations_shared/domain/services/ink_outline.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const rules = EditorRules();
const settings = InkSettings();

NoteDocument paper(List<Object?> items) => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'blank'},
  },
  'items': items,
}, schema: DocumentSchema('note-original', 1));

List<Map<String, Object?>> itemsOf(NoteDocument d) => [
  for (final it in d.toJson()['items'] as List) it as Map<String, Object?>,
];
Map<String, Object?> itemOf(NoteDocument d, String id) =>
    itemsOf(d).firstWhere((it) => it['id'] == id);
List<String> idsOf(NoteDocument d) => [
  for (final it in itemsOf(d)) it['id'] as String,
];
StrokeItem strokeOf(NoteDocument d, String id) => (d as PaperDocument).items
    .whereType<StrokeItem>()
    .firstWhere((s) => s.id == id);
List<InkNode> nodesOf(Map<String, Object?> item) => [
  for (final n in item['nodes'] as List)
    InkNode.fromJson(n as Map<String, Object?>),
];

Map<String, Object?> text(String id, num x, num y, num w, num h) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': w,
  'height': h,
  'spans': [
    {'text': 'Block $id'},
  ],
};

const round = BrushSettings(tool: InkTool.round, width: 3, color: '#000000FF');

/// A captured stroke from sample points (page units), with optional pressure
/// and tilt per sample.
Map<String, Object?> capture(
  String id,
  List<(double, double)> points, {
  BrushSettings brush = round,
  double? Function(int)? pressure,
  double? Function(int)? tilt,
  int Function(int)? time,
}) {
  final c = StrokeCapture(brush, pageWidth: 1000);
  for (var i = 0; i < points.length; i++) {
    c.add(
      points[i].$1,
      points[i].$2,
      1000 + (time?.call(i) ?? i * 8),
      pressure: pressure?.call(i),
      tilt: tilt?.call(i),
    );
  }
  return c.toItem(id)!;
}

/// Handwriting-like samples: a wave with loops, about one unit apart.
List<(double, double)> handwriting({double x0 = 100, double y0 = 200}) => [
  for (var i = 0; i < 400; i++)
    (
      x0 + i * 0.9 + 12 * math.sin(i / 7),
      y0 + 25 * math.sin(i / 11) + 10 * math.cos(i / 7),
    ),
];

/// A straight horizontal stroke from x0 to x1 at y, one sample per unit.
Map<String, Object?> line(
  String id,
  double x0,
  double x1,
  double y, {
  BrushSettings brush = round,
  bool pressure = false,
}) => capture(
  id,
  [for (var x = x0; x <= x1; x += 1) (x, y)],
  brush: brush,
  pressure: pressure ? (i) => 0.2 + (i % 10) / 20 : null,
  tilt: pressure ? (i) => 0.5 : null,
);

double distanceToPolyline(InkVec p, List<InkVec> line) {
  var best = double.infinity;
  for (var k = 1; k < line.length; k++) {
    best = math.min(best, distanceToSegment(p, line[k - 1], line[k]));
  }
  return line.length == 1 ? p.distanceTo(line.first) : best;
}

List<InkVec> curveOf(List<InkNode> nodes, {bool closed = false}) => [
  for (final p in flatten(
    segmentsOf(nodes, closed: closed),
    0.01,
    single: nodes.first.point,
  ))
    p.point,
];

ui.Path pathOf(InkOutline outline) {
  final path = ui.Path()..fillType = ui.PathFillType.nonZero;
  for (final piece in outline.pieces) {
    path.addPolygon([for (final v in piece) Offset(v.x, v.y)], true);
  }
  return path;
}

/// Renders strokes on white, one paint call per stroke, and returns RGBA.
Future<ByteData> render(List<InkOutline> outlines) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 200, 200),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  for (final o in outlines) {
    canvas.drawPath(pathOf(o), ui.Paint()..color = ui.Color(o.argb));
  }
  final image = await recorder.endRecording().toImage(200, 200);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

List<int> pixel(ByteData data, int x, int y) {
  final o = (y * 200 + x) * 4;
  return [for (var k = 0; k < 4; k++) data.getUint8(o + k)];
}

void main() {
  group('stored form', () {
    final dir = Directory('test/fixtures/document_schema/valid');
    test('fixture nodes keep their exact JSON through InkNode', () {
      var count = 0;
      for (final f in dir.listSync().whereType<File>()) {
        final raw = File(f.path).readAsStringSync();
        final body = (jsonDecode(raw) as Map)['document'] as Map;
        final items = [...?body['items'] as List?];
        for (final b in [...?body['blocks'] as List?]) {
          items.addAll([...?(b as Map)['ink'] as List?]);
        }
        for (final it in items) {
          for (final n in [...?(it as Map)['nodes'] as List?]) {
            final node = InkNode.fromJson((n as Map).cast<String, Object?>());
            expect(jsonEncode(node.toJson()), jsonEncode(n));
            count++;
          }
        }
      }
      expect(count, greaterThan(5));
    });

    test('samples and nodes survive save and load unchanged', () {
      final item = capture(
        's1',
        handwriting(),
        pressure: (i) => (i % 100) / 100,
        tilt: (i) => 0.3 + (i % 5) / 10,
      );
      final added = rules.addInk(paper([]), item);
      expect(added.accepted, isTrue);
      final saved = jsonEncode(added.document.toJson());
      final loaded = NoteDocument.fromJson(
        jsonDecode(saved),
        schema: DocumentSchema('note-original', 1),
      );
      expect(jsonEncode(loaded.toJson()), saved);
      final stroke = strokeOf(loaded, 's1');
      final samples = item['samples'] as Map;
      expect(stroke.samples.x, samples['x']);
      expect(stroke.samples.y, samples['y']);
      expect(stroke.samples.time, samples['t']);
      expect(stroke.samples.pressure, samples['pressure']);
      expect(stroke.samples.tilt, samples['tilt']);
      expect(
        jsonEncode([for (final n in stroke.nodes) n.toJson()]),
        jsonEncode(item['nodes']),
      );
      // A second save of the loaded document is byte-identical too, and the
      // document passes the same schema check as the backend.
      expect(jsonEncode(rules.check(loaded).document.toJson()), saved);
    });

    test('quantized units: hundredths, ms from start, pressure, tilt', () {
      final c = StrokeCapture(round, pageWidth: 1000)
        ..add(10.004, 20.5, 5000, pressure: 0.5, tilt: 0.7854)
        ..add(12, 21, 5016, pressure: 1.2, tilt: 2.0);
      final s = c.toItem('s')!['samples'] as Map;
      expect(s['x'], [1000, 1200]);
      expect(s['y'], [2050, 2100]);
      expect(s['t'], [0, 16]);
      expect(s['pressure'], [500, 1000]);
      expect(s['tilt'], [785, 1571]);
    });

    test('without real pressure there is no pressure column', () {
      final item = capture(
        's',
        [for (var i = 0; i < 50; i++) (100.0 + i * i * 0.2, 100.0)],
        brush: const BrushSettings(
          tool: InkTool.brush,
          width: 4,
          color: '#000000FF',
        ),
      );
      expect((item['samples'] as Map).containsKey('pressure'), isFalse);
      expect((item['samples'] as Map).containsKey('tilt'), isFalse);
      // Speed changes a lot, the width does not: every piece is 4 units wide.
      final outline = strokeOutline(strokeOf(paper([item]), 's'))!;
      for (final piece in outline.pieces) {
        final ys = piece.map((p) => p.y);
        expect(ys.reduce(math.max) - ys.reduce(math.min), closeTo(4, 1e-9));
      }
    });
  });

  group('editable nodes', () {
    test('fitted nodes stay within the tolerance and keep sample links', () {
      final points = handwriting();
      final item = capture('s', points);
      final nodes = nodesOf(item);
      final samples = [for (final (x, y) in points) InkVec(x, y)];
      expect(nodes.length, lessThan(points.length ~/ 4));
      expect(nodes.length, greaterThan(4));
      final curve = curveOf(nodes);
      const slack = 0.02; // storage rounding and flattening
      for (final s in samples) {
        expect(
          distanceToPolyline(s, curve),
          lessThanOrEqualTo(settings.fitTolerance + slack),
        );
      }
      for (final c in curve) {
        expect(
          distanceToPolyline(c, samples),
          lessThanOrEqualTo(settings.fitTolerance + slack),
        );
      }
      for (final n in nodes) {
        final i = n.sample!;
        final x = ((item['samples'] as Map)['x'] as List)[i];
        expect(n.x, x);
      }
    });

    test('jittery and sparse input also stays within the tolerance', () {
      final random = math.Random(7);
      final inputs = [
        [
          for (var i = 0; i < 600; i++)
            (
              300 + 80 * math.cos(i / 40) + random.nextDouble() * 0.6,
              300 + 80 * math.sin(i / 25) + random.nextDouble() * 0.6,
            ),
        ],
        [
          for (var i = 0; i < 40; i++)
            (100 + i * 6.0, 300 + 40 * math.sin(i / 3)),
        ],
      ];
      for (final points in inputs) {
        final nodes = nodesOf(capture('s', points));
        final curve = curveOf(nodes);
        final samples = [for (final (x, y) in points) InkVec(x, y)];
        for (final p in samples) {
          expect(distanceToPolyline(p, curve), lessThanOrEqualTo(0.52));
        }
        for (final c in curve) {
          expect(distanceToPolyline(c, samples), lessThanOrEqualTo(0.52));
        }
      }
    });

    test('a full stroke refuses more samples', () {
      final c = StrokeCapture(
        round,
        pageWidth: 1000,
        limits: const NoteLimits(maxSamplesPerStroke: 3),
      );
      expect(
        [for (var i = 0; i < 4; i++) c.add(1, 1, i)],
        [true, true, true, false],
      );
    });

    test('a sharp turn is a corner node; a dot is one node', () {
      final v = capture('v', [
        for (var i = 0; i <= 40; i++) (100.0 + i, 100.0 + i),
        for (var i = 1; i <= 40; i++) (140.0 + i, 140.0 - i),
      ]);
      final corners = nodesOf(v).where((n) => n.corner).toList();
      expect(corners, hasLength(1));
      expect(corners.single.point, const InkVec(140, 140));
      expect(nodesOf(capture('d', [(5, 5), (5, 5)])), hasLength(1));
    });

    final doc = paper([capture('s', handwriting())]);
    final before = itemOf(doc, 's');
    Map<String, Object?> edited(EditDecision d) {
      expect(d.accepted, isTrue, reason: '${d.error}');
      final after = itemOf(d.document, 's');
      // Point edits never touch the raw samples.
      expect(jsonEncode(after['samples']), jsonEncode(before['samples']));
      return after;
    }

    test('move a node with its handles', () {
      final after = nodesOf(edited(rules.moveNode(doc, 's', 2, 5, -3)));
      final old = nodesOf(before)[2];
      expect(after[2].point, old.point + const InkVec(5, -3));
      expect(after[2].outPoint, old.outPoint! + const InkVec(5, -3));
      expect(after[1].x, nodesOf(before)[1].x);
    });

    test('handle modes: independent, smooth and symmetric', () {
      const to = InkVec(300, 300);
      for (final mode in NodeMode.values) {
        final d = rules.setNodeMode(doc, 's', 2, mode);
        final n = nodesOf(
          edited(rules.moveHandle(d.document, 's', 2, NodeHandle.outgoing, to)),
        )[2];
        final set = nodesOf(itemOf(d.document, 's'))[2];
        expect(n.outPoint!.distanceTo(to), lessThan(0.01));
        final a = (n.outPoint! - n.point).normalized();
        final b = (n.inPoint! - n.point).normalized();
        switch (mode) {
          case NodeMode.independent:
            expect(n.incoming, set.incoming);
          case NodeMode.smooth:
            expect(a.dot(b), closeTo(-1, 1e-3));
            expect(
              n.inPoint!.distanceTo(n.point),
              closeTo(set.inPoint!.distanceTo(set.point), 0.02),
            );
          case NodeMode.symmetric:
            expect(a.dot(b), closeTo(-1, 1e-3));
            expect(
              n.inPoint!.distanceTo(n.point),
              closeTo(n.outPoint!.distanceTo(n.point), 0.02),
            );
        }
        expect(n.mode, mode);
      }
    });

    test('make corner and make smooth', () {
      final corner = nodesOf(edited(rules.makeCorner(doc, 's', 3)))[3];
      expect(corner.corner, isTrue);
      expect(corner.incoming, isNull);
      expect(corner.outgoing, isNull);
      final c = rules.makeCorner(doc, 's', 3).document;
      final smooth = nodesOf(edited(rules.makeSmooth(c, 's', 3)))[3];
      expect(smooth.corner, isFalse);
      expect(smooth.mode, NodeMode.smooth);
      final a = (smooth.outPoint! - smooth.point).normalized();
      final b = (smooth.inPoint! - smooth.point).normalized();
      expect(a.dot(b), closeTo(-1, 1e-3));
    });

    test('add a node keeps the curve; remove reconnects neighbors', () {
      final old = nodesOf(before);
      final added = nodesOf(edited(rules.addNode(doc, 's', 1, 0.5)));
      expect(added, hasLength(old.length + 1));
      final oldCurve = curveOf(old);
      for (final p in curveOf(added)) {
        expect(distanceToPolyline(p, oldCurve), lessThan(0.05));
      }
      expect(added[2].sample, greaterThan(old[1].sample!));
      expect(added[2].sample, lessThan(old[2].sample!));
      final removed = nodesOf(edited(rules.removeNode(doc, 's', 2)));
      expect(removed, hasLength(old.length - 1));
      expect(removed[1].point, old[1].point);
      expect(removed[2].point, old[3].point);
      // The new section passes near the removed node.
      expect(distanceToPolyline(old[2].point, curveOf(removed)), lessThan(10));
      expect(
        rules.removeNode(paper([line('l', 10, 20, 10)]), 'l', 0).error?.code,
        'too_few_nodes',
      );
    });

    test('one completed point drag is one Notes history step', () {
      final editor = NotesEditor(doc);
      for (var k = 1; k <= 5; k++) {
        // Previews during the drag never commit.
        rules.moveNode(editor.document, 's', 2, k, 0);
      }
      editor.apply(
        HistoryCommand(CommandKind.points),
        (r, d) => r.moveNode(d, 's', 2, 5, 0),
      );
      expect(editor.stepsBack, 1);
      editor.undo();
      expect(jsonEncode(editor.document.toJson()), jsonEncode(doc.toJson()));
    });
  });

  group('brushes', () {
    test(
      'every brush is versioned; unknown versions are not reinterpreted',
      () {
        for (final tool in InkTool.values) {
          expect(Brushes.current(tool), 1);
          expect(Brushes.of(tool.name, 1), isNotNull);
        }
        final future = {...line('s', 10, 50, 10), 'brush_version': 2};
        final d = paper([future]);
        expect(strokeOutline(strokeOf(d, 's')), isNull);
        // It is still saved exactly as it came.
        expect(jsonEncode(itemOf(d, 's')), jsonEncode(future));
      },
    );

    test('a setting change keeps the form; applying a pen changes it', () {
      final d = paper([line('s', 10, 50, 10)]);
      final styled = rules.restyleInk(d, ['s'], width: 6, color: '#FF0000FF');
      final s = itemOf(styled.document, 's');
      expect([s['tool'], s['brush_version'], s['width']], ['round', 1, 6]);
      expect(
        jsonEncode([s['samples'], s['nodes']]),
        jsonEncode([itemOf(d, 's')['samples'], itemOf(d, 's')['nodes']]),
      );
      final flat = rules.applyBrush(
        d,
        ['s'],
        const BrushSettings(
          tool: InkTool.flat,
          width: 8,
          color: '#000000FF',
          tipAngle: 0.5,
        ),
      );
      expect(flat.accepted, isTrue, reason: '${flat.error}');
      final f = itemOf(flat.document, 's');
      expect([f['tool'], f['tip_angle'], f['brush_version']], ['flat', 0.5, 1]);
      final back = rules.applyBrush(flat.document, ['s'], round);
      expect(itemOf(back.document, 's').containsKey('tip_angle'), isFalse);
    });

    test('brush width follows real pressure', () {
      const brush = BrushSettings(
        tool: InkTool.brush,
        width: 10,
        color: '#000000FF',
      );
      final item = capture(
        's',
        [for (var x = 10.0; x <= 110; x += 1) (x, 50.0)],
        brush: brush,
        pressure: (i) => i < 50 ? 0.0 : 1.0,
      );
      final o = strokeOutline(strokeOf(paper([item]), 's'))!;
      double heightAt(double x) {
        final ys = [
          for (final piece in o.pieces)
            for (final p in piece)
              if ((p.x - x).abs() < 6) p.y,
        ];
        return ys.reduce(math.max) - ys.reduce(math.min);
      }

      expect(heightAt(30), closeTo(4, 0.1)); // 0.4 x width at no pressure
      expect(heightAt(90), closeTo(16, 0.1)); // 1.6 x width at full pressure
    });

    test('flat pen: broad or narrow by direction', () {
      const flat = BrushSettings(
        tool: InkTool.flat,
        width: 10,
        color: '#000000FF',
        tipAngle: 0,
      );
      final across = capture('a', [
        for (var y = 10.0; y <= 60; y++) (50.0, y),
      ], brush: flat);
      final along = capture('b', [
        for (var x = 10.0; x <= 60; x++) (x, 50.0),
      ], brush: flat);
      final d = paper([across, along]);
      double extent(InkOutline o, bool xAxis) {
        final v = [
          for (final piece in o.pieces)
            for (final p in piece) xAxis ? p.x : p.y,
        ];
        return v.reduce(math.max) - v.reduce(math.min);
      }

      // A vertical move with a horizontal nib is broad (10), a horizontal
      // move is as thin as the nib (2).
      expect(extent(strokeOutline(strokeOf(d, 'a'))!, true), closeTo(10, 0.01));
      expect(extent(strokeOutline(strokeOf(d, 'b'))!, false), closeTo(2, 0.01));
    });

    testWidgets('highlighter: one opacity inside one stroke, darker overlap', (
      tester,
    ) async {
      const marker = BrushSettings(
        tool: InkTool.highlighter,
        width: 12,
        color: '#0000FFFF',
        opacity: 0.5,
      );
      // A figure eight crosses itself at (100, 100).
      final eight = capture('e', [
        for (var s = 0.3; s < 2 * math.pi + 0.3; s += 0.01)
          (100 + 70 * math.sin(s), 100 + 50 * math.sin(2 * s)),
      ], brush: marker);
      final h = line('h', 20, 180, 50, brush: marker);
      final v = capture('v', [
        for (var y = 10.0; y <= 90; y++) (100.0, y),
      ], brush: marker);
      final d = paper([eight, h, v]);
      await tester.runAsync(() async {
        final one = await render([strokeOutline(strokeOf(d, 'e'))!]);
        final crossing = pixel(one, 100, 100);
        final single = pixel(one, 149, 150);
        expect(single, isNot([255, 255, 255, 255]));
        expect(crossing, single);
        final two = await render([
          strokeOutline(strokeOf(d, 'h'))!,
          strokeOutline(strokeOf(d, 'v'))!,
        ]);
        final overlap = pixel(two, 100, 50);
        final alone = pixel(two, 60, 50);
        expect(alone, single);
        expect(overlap[0], lessThan(alone[0] - 40));
      });
    });
  });

  group('shapes', () {
    const style = ShapeStyle(
      color: '#DC2626FF',
      lineWidth: 2,
      fill: '#FEE2E280',
    );
    final circle = InkShapes.circle('c', const InkVec(200, 200), 50, style);
    final rect = InkShapes.rectangle(
      'r',
      const InkVec(400, 100),
      200,
      80,
      style,
    );
    final tri = InkShapes.triangle('t', const [
      InkVec(100, 400),
      InkVec(200, 400),
      InkVec(150, 320),
    ], style);
    final d = paper([circle, rect, tri]);

    test('shapes stay geometric when resized and moved', () {
      expect(rules.check(d).accepted, isTrue);
      final r = rules.resize(d, 'c', width: 200);
      expect(itemOf(r.document, 'c')['shape'], 'circle');
      expect(itemOf(r.document, 'c')['radius'], 100);
      final m = rules.move(d, ['r'], 10, 10);
      expect(itemOf(m.document, 'r')['shape'], 'rectangle');
      expect(
        shapeOutline((d as PaperDocument).items.first as ShapeItem),
        isNotNull,
      );
    });

    test('Edit as path converts with the same look, id and style', () {
      final c = rules.editAsPath(d, 'c');
      expect(c.accepted, isTrue, reason: '${c.error}');
      final path = itemOf(c.document, 'c');
      expect(path['shape'], 'path');
      expect(path['closed'], isTrue);
      expect(path['fill'], '#FEE2E280');
      expect(path.containsKey('radius'), isFalse);
      for (final p in curveOf(nodesOf(path), closed: true)) {
        expect(p.distanceTo(const InkVec(200, 200)), closeTo(50, 0.05));
      }
      final r = itemOf(rules.editAsPath(d, 'r').document, 'r');
      expect(nodesOf(r).map((n) => n.point), const [
        InkVec(400, 100),
        InkVec(600, 100),
        InkVec(600, 180),
        InkVec(400, 180),
      ]);
      expect(nodesOf(r).every((n) => n.corner), isTrue);
      final t = rules.editAsPath(d, 't');
      expect(nodesOf(itemOf(t.document, 't')), hasLength(3));
      // After the conversion, point editing works on the path.
      final moved = rules.moveNode(
        rules.editAsPath(d, 'r').document,
        'r',
        2,
        20,
        20,
      );
      expect(moved.accepted, isTrue, reason: '${moved.error}');
      expect(rules.editAsPath(c.document, 'c').error?.code, 'not_editable');
      expect(rules.moveNode(d, 'c', 0, 1, 1).error?.code, 'not_editable');
    });
  });

  group('erasing', () {
    var next = 0;
    String newId() => 'n${next++}';
    final stroke = line('s', 100, 300, 100, pressure: true);
    final doc = paper([
      line('a', 100, 300, 300),
      stroke,
      text('t', 504, 504, 104, 50),
    ]);

    test('partial erase splits with new ids and keeps pressure and tilt', () {
      final d = rules.erase(
        doc,
        from: const InkVec(200, 80),
        to: const InkVec(200, 120),
        radius: 5,
        mode: EraserMode.partialStroke,
        newId: newId,
      );
      expect(d.accepted, isTrue, reason: '${d.error}');
      final ids = idsOf(d.document);
      expect(ids.first, 'a');
      expect(ids.last, 't');
      expect(ids, hasLength(4));
      expect(ids.contains('s'), isFalse);
      final pieces = [itemOf(d.document, ids[1]), itemOf(d.document, ids[2])];
      final samples = stroke['samples'] as Map;
      for (final p in pieces) {
        for (final key in [
          'tool',
          'brush_version',
          'width',
          'color',
          'opacity',
        ]) {
          expect(p[key], stroke[key]);
        }
        final s = p['samples'] as Map;
        expect(s['pressure'], isNotNull);
        expect(s['tilt'], isNotNull);
        expect((s['pressure'] as List).length, (s['x'] as List).length);
        expect((s['t'] as List).first, 0);
        // Every pressure value comes from the raw pressure of the stroke.
        final raw = (samples['pressure'] as List).cast<int>();
        for (final v in (s['pressure'] as List).cast<int>()) {
          expect(
            v,
            inInclusiveRange(raw.reduce(math.min), raw.reduce(math.max)),
          );
        }
      }
      // The cut is at the eraser edge: radius 5 plus half the width 3.
      final left = nodesOf(pieces[0]).last.point.x;
      final right = nodesOf(pieces[1]).first.point.x;
      expect(left, closeTo(200 - 6.5, 0.05));
      expect(right, closeTo(200 + 6.5, 0.05));
      // Raw samples between the cut ends are kept as they were.
      final xs = (pieces[0]['samples'] as Map)['x'] as List;
      expect(xs.first, 10000);
      expect(xs[1], 10100);
      // Saving and loading the fragments is byte-stable.
      final saved = jsonEncode(d.document.toJson());
      expect(
        jsonEncode(
          NoteDocument.fromJson(
            jsonDecode(saved),
            schema: d.document.schema,
          ).toJson(),
        ),
        saved,
      );
    });

    test('fragments of a curved stroke follow the original curve', () {
      final curved = capture(
        'c',
        handwriting(),
        pressure: (i) => (i % 50) / 50,
        tilt: (i) => 1.0,
      );
      final original = curveOf(nodesOf(curved));
      var d = paper([curved]);
      for (final x in [180.0, 260.0]) {
        d = rules
            .erase(
              d,
              from: InkVec(x, 100),
              to: InkVec(x, 300),
              radius: 3,
              mode: EraserMode.partialStroke,
              newId: newId,
            )
            .document;
      }
      final pieces = itemsOf(d);
      expect(pieces.length, greaterThanOrEqualTo(3));
      for (final p in pieces) {
        expect(p['id'], isNot('c'));
        final s = p['samples'] as Map;
        expect((s['pressure'] as List).length, (s['x'] as List).length);
        expect((s['tilt'] as List).toSet(), {1000});
        for (final c in curveOf(nodesOf(p))) {
          expect(distanceToPolyline(c, original), lessThan(0.05));
        }
        for (final n in nodesOf(p)) {
          expect(n.sample, inInclusiveRange(0, (s['x'] as List).length - 1));
        }
      }
      expect(rules.check(d).accepted, isTrue);
    });

    test('whole-stroke erase removes the stroke', () {
      final d = rules.erase(
        doc,
        from: const InkVec(200, 100),
        to: const InkVec(200, 100),
        radius: 2,
        mode: EraserMode.wholeStroke,
        newId: newId,
      );
      expect(idsOf(d.document), ['a', 't']);
    });

    test('the normal eraser never touches text, cards or grouped ink', () {
      final grouped = paper([
        text('t', 104, 104, 200, 100),
        line('g', 120, 200, 150),
        {
          'id': 'grp',
          'kind': 'group',
          'members': ['t', 'g'],
        },
        {
          'id': 'l',
          'kind': 'link_card',
          'url': 'https://example.org/',
          'x': 400,
          'y': 104,
          'width': 200,
          'height': 100,
        },
      ]);
      for (final mode in EraserMode.values) {
        for (final (x, y) in [(150.0, 150.0), (500.0, 150.0), (150.0, 120.0)]) {
          final d = rules.erase(
            grouped,
            from: InkVec(x, y),
            to: InkVec(x + 30, y),
            radius: 10,
            mode: mode,
            newId: newId,
          );
          expect(d.accepted, isTrue);
          expect(jsonEncode(d.document.toJson()), jsonEncode(grouped.toJson()));
        }
      }
    });

    test(
      'dangerous erase: the hidden object under the top object survives',
      () {
        // Ink lies over the text block; the eraser touches both.
        final start = paper([
          text('t', 104, 104, 192, 100),
          line('ink', 100, 300, 150),
          text('other', 400, 128, 104, 50),
        ]);
        final editor = NotesEditor(start);
        final gesture = InkEraseGesture.begin(
          editor,
          at: const InkVec(200, 150),
          radius: 4,
          dangerous: true,
          newId: newId,
        );
        expect(idsOf(editor.document), ['t', 'other']);
        // The eraser keeps rubbing where the ink was: the text below was hidden
        // at the gesture start, so it stays.
        gesture.moveTo(const InkVec(220, 150));
        gesture.moveTo(const InkVec(180, 151));
        expect(idsOf(editor.document), ['t', 'other']);
        // Moving on along the ink to a visible object removes it whole; the
        // text under the ink still survives.
        gesture.moveTo(const InkVec(420, 150));
        expect(idsOf(editor.document), ['t']);
        expect(gesture.end(), isTrue);
        expect(editor.stepsBack, 1);
        editor.undo();
        expect(
          jsonEncode(editor.document.toJson()),
          jsonEncode(start.toJson()),
        );
      },
    );

    test('dangerous erase removes a whole group', () {
      final start = paper([
        text('t', 104, 104, 200, 100),
        line('g', 120, 200, 300),
        {
          'id': 'grp',
          'kind': 'group',
          'members': ['t', 'g'],
        },
        text('u', 400, 400, 104, 50),
      ]);
      final d = rules.eraseObjects(
        start,
        start: start,
        from: const InkVec(150, 120),
        to: const InkVec(150, 120),
        radius: 3,
      );
      expect(d.accepted, isTrue, reason: '${d.error}');
      expect(idsOf(d.document), ['u']);
    });

    test('live erase is one step; a cancelled gesture restores the state', () {
      final editor = NotesEditor(doc);
      final g = InkEraseGesture.begin(
        editor,
        at: const InkVec(150, 100),
        radius: 3,
        newId: newId,
      );
      for (var x = 150.0; x <= 250; x += 10) {
        g.moveTo(InkVec(x, 100));
      }
      expect(idsOf(editor.document).length, 4);
      g.cancel();
      expect(jsonEncode(editor.document.toJson()), jsonEncode(doc.toJson()));
      expect(editor.stepsBack, 0);

      final h = InkEraseGesture.begin(
        editor,
        at: const InkVec(150, 100),
        radius: 3,
        newId: newId,
      );
      for (var x = 150.0; x <= 250; x += 10) {
        h.moveTo(InkVec(x, 100));
      }
      h.end();
      expect(editor.stepsBack, 1);
      editor.undo();
      expect(jsonEncode(editor.document.toJson()), jsonEncode(doc.toJson()));
    });

    NoteDocument square() => paper([
      InkShapes.rectangle(
        'r',
        const InkVec(100, 100),
        100,
        100,
        const ShapeStyle(color: '#000000FF', lineWidth: 2, fill: '#BFDBFE80'),
      ),
    ]);

    test('whole-stroke mode removes a touched shape', () {
      final e = rules.erase(
        square(),
        from: const InkVec(100, 150),
        to: const InkVec(100, 150),
        radius: 3,
        mode: EraserMode.wholeStroke,
        newId: newId,
      );
      expect(idsOf(e.document), isEmpty);
    });

    test('partial mode leaves the untouched outline as an editable path', () {
      final d = square();
      final editor = NotesEditor(d);
      final e = editor.apply(
        HistoryCommand(CommandKind.erase),
        (rules, doc) => rules.erase(
          doc,
          from: const InkVec(100, 150),
          to: const InkVec(100, 150),
          radius: 3,
          mode: EraserMode.partialStroke,
          newId: newId,
        ),
      );
      expect(e.accepted, isTrue, reason: '${e.error}');
      final items = editor.document.toJson()['items'] as List;
      expect(items, hasLength(1), reason: 'one piece: the outline continues');
      final path = items.single as Map;
      expect(path['id'], isNot('r'));
      expect(path['shape'], 'path');
      expect(path['closed'], isFalse);
      expect(path['color'], '#000000FF');
      expect(path['line_width'], 2);
      expect(path.containsKey('fill'), isFalse);
      // The open path runs from below the gap round the square to above it:
      // the three other corners stay as nodes.
      final nodes = [
        for (final n in path['nodes'] as List)
          ((n as Map)['x'] as int, n['y'] as int),
      ];
      expect(nodes, contains((20000, 10000)));
      expect(nodes, contains((20000, 20000)));
      expect(nodes, contains((10000, 10000)));
      final ends = [nodes.first, nodes.last];
      for (final (x, y) in ends) {
        expect(x, 10000);
        expect((y - 15000).abs(), greaterThan(300));
        expect((y - 15000).abs(), lessThan(800));
      }
      // The path is editable like any path: a node moves.
      final moved = editor.rules.moveNode(
        editor.document,
        path['id'] as String,
        1,
        5,
        0,
      );
      expect(moved.accepted, isTrue, reason: '${moved.error}');
      // One Undo restores the original shape.
      editor.undo();
      expect(jsonEncode(editor.document.toJson()), jsonEncode(d.toJson()));
    });

    test('partial mode across a circle splits it into two paths', () {
      final d = paper([
        InkShapes.circle(
          'c',
          const InkVec(300, 300),
          50,
          const ShapeStyle(color: '#3D5AFEFF', lineWidth: 2),
        ),
      ]);
      final e = rules.erase(
        d,
        from: const InkVec(240, 300),
        to: const InkVec(360, 300),
        radius: 4,
        mode: EraserMode.partialStroke,
        newId: newId,
      );
      final items = e.document.toJson()['items'] as List;
      expect(items, hasLength(2));
      for (final it in items.cast<Map>()) {
        expect(it['shape'], 'path');
        expect(it['closed'], isFalse);
      }
    });
  });
}
