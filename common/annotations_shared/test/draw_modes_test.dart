// Type and Draw modes, the four pens, tool settings and shapes
// (annotations#28): editing starts in Type mode, the switch keeps content
// and history, a mouse draws with the fixed width, a setting change never
// reshapes earlier strokes and reaches only selected ink, each tool keeps
// its settings, ink over text never opens a text cursor, and a finger draws
// only with its option on.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:annotations_shared/core/draw_settings.dart';
import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/draw_tools.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/ink_outline.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/handlers/draw_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/text_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';
import 'paper_canvas_test.dart'
    show handlerFor, schema, setWindow, stroke, text;

/// A page with a text block, two strokes and a rectangle.
NoteDocument drawNote() => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'grid', 'spacing': 24, 'visibility': 0.5},
  },
  'items': [
    text('title', 40, 40, 520, 32, [
      {'text': 'Cell structure', 'size': 24, 'bold': true},
    ]),
    text('body', 40, 104, 424, 48, [
      {'text': 'The membrane controls what enters the cell.'},
    ]),
    stroke('ink1', 40, 260, length: 300, width: 4),
    stroke('ink2', 40, 320, length: 220, width: 6, color: '#FF1744FF'),
    {
      'id': 'box',
      'kind': 'shape',
      'shape': 'rectangle',
      'color': '#3D5AFEFF',
      'line_width': 2,
      'opacity': 1,
      'x': 600,
      'y': 240,
      'width': 200,
      'height': 120,
    },
  ],
}, schema: schema);

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('drawing tools (domain)', () {
    test('the round pen is the first tool and each tool keeps its own', () {
      final tools = DrawTools.initial();
      expect(tools.active, DrawTool.round);
      final changed = tools
          .changed(DrawTool.round, const InkStyleChange(width: 9))
          .changed(DrawTool.flat, const InkStyleChange(color: '#FF1744FF'));
      expect(changed.pen(InkTool.round).width, 9);
      expect(changed.pen(InkTool.round).color, '#000000FF');
      expect(changed.pen(InkTool.flat).color, '#FF1744FF');
      expect(changed.pen(InkTool.flat).width, const DrawSettings().flatWidth);
      expect(changed.pen(InkTool.brush).width, const DrawSettings().brushWidth);
      // Only the flat pen has a tip angle.
      expect(
        changed
            .changed(DrawTool.round, const InkStyleChange(tipAngle: 1))
            .pen(InkTool.round)
            .tipAngle,
        isNull,
      );
      final back = DrawTools.fromJson(
        jsonDecode(jsonEncode(changed.withActive(DrawTool.shapes).toJson())),
      );
      expect(back.active, DrawTool.shapes);
      expect(back.pen(InkTool.round).width, 9);
      expect(back.pen(InkTool.flat).color, '#FF1744FF');
      expect(
        back.pen(InkTool.flat).tipAngle,
        const DrawSettings().flatTipAngle,
      );
    });

    test('a damaged device value keeps the first settings', () {
      final tools = DrawTools.fromJson({
        'active': 'laser',
        'round': {'width': -2, 'color': 'red', 'opacity': 3},
        'shapes': {'shape': 'star'},
      });
      expect(tools.active, DrawTool.round);
      expect(tools.pen(InkTool.round).width, const DrawSettings().roundWidth);
      expect(tools.pen(InkTool.round).color, '#000000FF');
      expect(tools.pen(InkTool.round).opacity, 1);
      expect(tools.shape.kind, ShapeKind.rectangle);
      expect(DrawTools.fromJson('x').active, DrawTool.round);
    });

    test('a shape drag gives a geometric shape; a click gives none', () {
      const style = ShapeStyle(color: '#000000FF', lineWidth: 2);
      final rect = shapeFromDrag(
        'r',
        ShapeKind.rectangle,
        const InkVec(300, 200),
        const InkVec(100, 120),
        style,
      )!;
      expect(
        [rect['x'], rect['y'], rect['width'], rect['height']],
        [100, 120, 200, 80],
      );
      final circle = shapeFromDrag(
        'c',
        ShapeKind.circle,
        const InkVec(100, 100),
        const InkVec(160, 140),
        style,
      )!;
      expect(circle['radius'], 30);
      expect(circle['center'], {'x': 130, 'y': 130});
      final triangle = shapeFromDrag(
        't',
        ShapeKind.triangle,
        const InkVec(0, 0),
        const InkVec(100, 50),
        style,
      )!;
      expect(triangle['points'], [
        {'x': 50, 'y': 0},
        {'x': 100, 'y': 50},
        {'x': 0, 'y': 50},
      ]);
      expect(
        shapeFromDrag(
          'x',
          ShapeKind.rectangle,
          const InkVec(10, 10),
          const InkVec(12, 11),
          style,
        ),
        isNull,
      );
      for (final shape in [rect, circle, triangle]) {
        expect(const EditorRules().addInk(drawNote(), shape).accepted, isTrue);
      }
    });

    test('selected ink is the strokes and shapes of the selection', () {
      final layout = DocumentLayout.of(drawNote())!;
      expect(selectedInk(layout, ObjectSelection(['body', 'ink2', 'box'])), [
        'ink2',
        'box',
      ]);
      expect(selectedInk(layout, ObjectSelection(['title'])), isEmpty);
    });
  });

  group('Type and Draw on the paper', () {
    late PaperHandler paper;
    late TextHandler texts;
    late DrawHandler draw;
    late Preferences preferences;
    var ids = 0;

    Future<void> pump(
      WidgetTester tester, {
      NoteDocument? document,
      Brightness brightness = Brightness.light,
      Size size = const Size(1280, 900),
      Preferences? prefs,
    }) async {
      await setWindow(tester, size);
      ids = 0;
      paper = handlerFor(document ?? drawNote());
      preferences = prefs ?? Preferences();
      texts = TextHandler(
        paper: paper,
        preferences: preferences,
        newId: () => 'text${ids++}',
      );
      draw = DrawHandler(
        paper: paper,
        preferences: preferences,
        onDrawMode: texts.end,
        newId: () => 'new${ids++}',
      );
      addTearDown(texts.dispose);
      addTearDown(draw.dispose);
      await tester.pumpWidget(
        AppScope(
          preferences: preferences,
          service: fixtureService(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(brightness),
            localizationsDelegates:
                FlutterQuillLocalizations.localizationsDelegates,
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: Material(
                child: PaperScreen(handler: paper, text: texts, draw: draw),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Offset screenOf(double x, double y) =>
        paper.view.value!.toScreen(Offset(x, y));

    Finder byKey(String key) => find.byKey(Key(key));

    Map<String, Object?>? item(String id) {
      for (final it in paper.document.toJson()['items'] as List) {
        if ((it as Map)['id'] == id) return it.cast<String, Object?>();
      }
      return null;
    }

    List<Map<String, Object?>> items() => [
      for (final it in paper.document.toJson()['items'] as List)
        (it as Map).cast<String, Object?>(),
    ];

    NotesEditor notes() => paper.session as NotesEditor;

    /// A drag on the page with [kind] through [points] (page units).
    Future<void> drag(
      WidgetTester tester,
      List<Offset> points, {
      PointerDeviceKind kind = PointerDeviceKind.mouse,
      int pointer = 1,
    }) async {
      final g = await tester.createGesture(kind: kind, pointer: pointer);
      await g.down(screenOf(points.first.dx, points.first.dy));
      await tester.pump();
      for (final p in points.skip(1)) {
        await g.moveTo(screenOf(p.dx, p.dy));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
    }

    List<Offset> line(double x, double y, {double length = 200}) => [
      for (var i = 0; i <= 10; i++)
        Offset(x + length * i / 10, y + (i.isEven ? 0 : 8)),
    ];

    Future<void> finish(WidgetTester tester) async {
      texts.end();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    Future<void> toDraw(WidgetTester tester) async {
      await tester.tap(byKey('mode-draw'));
      await tester.pump();
    }

    testWidgets('editing starts in Type mode with the switch visible', (
      tester,
    ) async {
      await pump(tester);
      expect(draw.mode, SelectionTool.type);
      expect(byKey('mode-switch'), findsOneWidget);
      expect(byKey('draw-tools'), findsNothing);
      // A mouse drag in Type mode draws nothing.
      await drag(tester, line(60, 600));
      expect(items(), hasLength(5));
      await toDraw(tester);
      expect(draw.mode, SelectionTool.draw);
      expect(paper.tool, SelectionTool.draw);
      expect(byKey('mode-switch'), findsOneWidget);
      expect(byKey('draw-tools'), findsOneWidget);
      expect(draw.tools.active, DrawTool.round);
      expect(
        tester.getSemantics(byKey('mode-draw')).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      await finish(tester);
    });

    testWidgets('switching modes keeps content, selection and history', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      await drag(tester, line(60, 600));
      expect(notes().stepsBack, 1);
      paper.select(ObjectSelection(['ink1']));
      final before = jsonEncode(paper.document.toJson());
      for (var i = 0; i < 3; i++) {
        await tester.tap(byKey('mode-type'));
        await tester.pump();
        await toDraw(tester);
      }
      expect(jsonEncode(paper.document.toJson()), before);
      expect(notes().stepsBack, 1);
      expect(notes().stepsForward, 0);
      expect(paper.selection.value, ObjectSelection(['ink1']));
      // The document has no mode: it is local editor state.
      expect(before.contains('draw'), isFalse);
      notes().undo();
      expect(items(), hasLength(5));
      await finish(tester);
    });

    testWidgets('a mouse without pressure draws with the fixed width', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      draw.selectTool(DrawTool.brush);
      await drag(tester, line(60, 600));
      final s = item('new0')!;
      expect(s['tool'], 'brush');
      expect(s['width'], const DrawSettings().brushWidth);
      final samples = s['samples'] as Map;
      expect(samples.containsKey('pressure'), isFalse);
      expect((samples['x'] as List).length, 11);
      // The outline has the selected width everywhere.
      final outline = strokeOutline(
        DocumentItem.fromJson(s, family: DocumentFamily.original) as StrokeItem,
      )!;
      final widths = <double>{};
      for (final piece in outline.pieces) {
        final ys = piece.map((v) => v.y);
        widths.add(
          (ys.reduce((a, b) => a > b ? a : b) -
                  ys.reduce((a, b) => a < b ? a : b))
              .roundToDouble(),
        );
      }
      expect(widths.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(14));
      expect(
        Brushes.of('brush', 1)!.widthScale(null),
        1,
        reason: 'no pressure is the selected width',
      );
      expect(notes().stepsBack, 1, reason: 'one stroke is one step');
      expect(paper.activeInk.value, isNull);
      await finish(tester);
    });

    testWidgets('a pen stores its pressure; the eraser end draws nothing', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      draw.selectTool(DrawTool.brush);
      final points = line(60, 600);
      final start = screenOf(points.first.dx, points.first.dy);
      tester.binding.handlePointerEvent(
        PointerDownEvent(
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          position: start,
          pressure: 0.2,
          pressureMin: 0,
          pressureMax: 1,
        ),
      );
      for (final (i, p) in points.skip(1).indexed) {
        tester.binding.handlePointerEvent(
          PointerMoveEvent(
            pointer: 7,
            kind: PointerDeviceKind.stylus,
            position: screenOf(p.dx, p.dy),
            pressure: 0.2 + i * 0.07,
            pressureMin: 0,
            pressureMax: 1,
            timeStamp: Duration(milliseconds: 8 * (i + 1)),
          ),
        );
      }
      tester.binding.handlePointerEvent(
        PointerUpEvent(
          pointer: 7,
          kind: PointerDeviceKind.stylus,
          position: screenOf(points.last.dx, points.last.dy),
          pressureMin: 0,
          pressureMax: 1,
        ),
      );
      await tester.pump();
      final pressure = (item('new0')!['samples'] as Map)['pressure'] as List;
      expect(pressure.first, 200);
      expect(pressure[5], greaterThan(pressure.first as int));
      await drag(tester, line(60, 700), kind: PointerDeviceKind.invertedStylus);
      expect(items(), hasLength(6));
      await finish(tester);
    });

    testWidgets('a pen setting change never changes earlier strokes', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      await drag(tester, line(60, 600));
      final first = jsonEncode(item('new0'));
      final steps = notes().stepsBack;
      draw.change(const InkStyleChange(width: 12, color: '#3D5AFEFF'));
      draw.change(const InkStyleChange(opacity: 0.5));
      expect(jsonEncode(item('new0')), first);
      expect(notes().stepsBack, steps, reason: 'tool settings are no step');
      await drag(tester, line(60, 700));
      final second = item('new1')!;
      expect(second['width'], 12);
      expect(second['color'], '#3D5AFEFF');
      expect(second['opacity'], 0.5);
      expect(jsonEncode(item('new0')), first);
      await finish(tester);
    });

    testWidgets('with ink selected a change reaches only that ink', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      final ink1 = jsonEncode(item('ink1'));
      final body = jsonEncode(item('body'));
      final tool = draw.tools.pen(InkTool.round);
      paper.select(ObjectSelection(['ink2', 'box', 'body']));
      expect(draw.editsSelection, isTrue);
      expect(draw.style.width, 6, reason: 'the panel shows the selection');
      // A slider drag shows its value and changes nothing until its end.
      draw.change(const InkStyleChange(width: 9), done: false);
      expect(draw.style.width, 9);
      expect(item('ink2')!['width'], 6);
      draw.change(const InkStyleChange(width: 10));
      expect(item('ink2')!['width'], 10);
      expect(item('box')!['line_width'], 10);
      expect(notes().stepsBack, 1, reason: 'one change is one step');
      draw.change(const InkStyleChange(color: '#00C853FF'));
      expect(item('ink2')!['color'], '#00C853FF');
      expect(item('box')!['color'], '#00C853FF');
      expect(notes().stepsBack, 2);
      // Unselected ink, text and the tool settings stay.
      expect(jsonEncode(item('ink1')), ink1);
      expect(jsonEncode(item('body')), body);
      expect(draw.tools.pen(InkTool.round).width, tool.width);
      expect(draw.tools.pen(InkTool.round).color, tool.color);
      // The shape keeps its form: the tool and brush version of a stroke
      // stay, so the line is not reshaped.
      expect(item('ink2')!['tool'], 'round');
      expect(item('ink2')!['nodes'], isNotEmpty);
      notes().undo();
      expect(item('ink2')!['color'], '#FF1744FF');
      expect(item('ink2')!['width'], 10);
      await finish(tester);
    });

    testWidgets('each tool remembers its settings on this device', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      draw.change(const InkStyleChange(width: 5, color: '#FF1744FF'));
      draw.selectTool(DrawTool.flat);
      draw.change(const InkStyleChange(tipAngle: 1.2, width: 14));
      draw.selectTool(DrawTool.highlighter);
      expect(draw.style.opacity, const DrawSettings().highlighterOpacity);
      draw.selectTool(DrawTool.round);
      expect(draw.style.width, 5);
      expect(draw.style.color, '#FF1744FF');
      draw.selectTool(DrawTool.flat);
      expect(draw.style.width, 14);
      expect(draw.style.tipAngle, 1.2);
      await drag(tester, line(60, 600));
      expect(item('new0')!['tool'], 'flat');
      expect(item('new0')!['tip_angle'], 1.2);
      // Another editor on this device starts with the same tools.
      final again = Preferences();
      await again.load();
      expect(again.drawTools.active, DrawTool.flat);
      expect(again.drawTools.pen(InkTool.round).width, 5);
      expect(again.drawTools.pen(InkTool.flat).tipAngle, 1.2);
      await finish(tester);
    });

    testWidgets('ink over text never opens a text cursor in Draw mode', (
      tester,
    ) async {
      await pump(tester);
      // An open block closes when Draw mode starts.
      await tester.tapAt(screenOf(60, 110));
      await tester.pump();
      await tester.pump();
      expect(texts.editing, 'body');
      await toDraw(tester);
      expect(texts.editing, isNull);
      // A click on text draws a dot and opens nothing.
      await drag(tester, [const Offset(60, 110)]);
      await tester.pump();
      expect(texts.editing, isNull);
      expect(item('new0')!['kind'], 'stroke');
      // A stroke across the text block is ink; the text stays.
      final body = jsonEncode(item('body'));
      await drag(tester, line(50, 110, length: 380));
      await tester.pump();
      expect(texts.editing, isNull);
      expect(item('new1')!['kind'], 'stroke');
      expect(jsonEncode(item('body')), body);
      expect(find.byType(QuillEditor), findsNothing);
      await finish(tester);
    });

    testWidgets('a finger draws only when finger drawing is on', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      expect(preferences.fingerDrawing, isFalse);
      await drag(tester, line(60, 600), kind: PointerDeviceKind.touch);
      expect(items(), hasLength(5));
      await preferences.setFingerDrawing(true);
      final scroll = paper.view.value!.scroll;
      await drag(tester, line(60, 600), kind: PointerDeviceKind.touch);
      expect(items(), hasLength(6));
      expect(paper.view.value!.scroll, scroll, reason: 'drawing never pans');
      // A second finger stops the stroke: nothing is stored.
      final a = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 21,
      );
      await a.down(screenOf(60, 700));
      await a.moveTo(screenOf(120, 720));
      await tester.pump();
      expect(draw.isDrawing, isTrue);
      final b = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 22,
      );
      await b.down(screenOf(300, 700));
      await tester.pump();
      expect(draw.isDrawing, isFalse);
      expect(paper.activeInk.value, isNull);
      await a.up();
      await b.up();
      await tester.pump();
      expect(items(), hasLength(6));
      await finish(tester);
    });

    testWidgets('switching modes during a stroke cancels it safely', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      final g = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await g.down(screenOf(60, 600));
      await g.moveTo(screenOf(120, 610));
      await tester.pump();
      expect(paper.activeInk.value, isNotNull);
      draw.setMode(SelectionTool.type);
      expect(paper.activeInk.value, isNull);
      await g.moveTo(screenOf(180, 620));
      await g.up();
      await tester.pump();
      expect(items(), hasLength(5));
      expect(notes().stepsBack, 0);
      await finish(tester);
    });

    testWidgets('the highlighter is broad and transparent', (tester) async {
      await pump(tester);
      await toDraw(tester);
      draw.selectTool(DrawTool.highlighter);
      await drag(tester, line(40, 120, length: 300));
      final h = item('new0')!;
      expect(h['tool'], 'highlighter');
      expect(h['width'], const DrawSettings().highlighterWidth);
      expect(h['opacity'], const DrawSettings().highlighterOpacity);
      expect(item('body')!['spans'], isNotEmpty);
      await finish(tester);
    });

    testWidgets('shapes: draw, choose the kind, Edit as path', (tester) async {
      await pump(tester);
      await toDraw(tester);
      await tester.tap(byKey('draw-tool-shapes'));
      await tester.pump();
      expect(draw.tools.active, DrawTool.shapes);
      await drag(tester, [const Offset(100, 500), const Offset(300, 620)]);
      final rect = item('new0')!;
      expect(rect['shape'], 'rectangle');
      expect(
        [rect['x'], rect['y'], rect['width'], rect['height']],
        [100, 500, 200, 120],
      );
      // Tapping the active tool opens its settings with the shape choice.
      await tester.tap(byKey('draw-tool-shapes'));
      await tester.pumpAndSettle();
      expect(byKey('draw-settings'), findsOneWidget);
      expect(byKey('edit-as-path'), findsNothing);
      await tester.tap(byKey('shape-circle'));
      await tester.pumpAndSettle();
      expect(draw.tools.shape.kind, ShapeKind.circle);
      await tester.tapAt(const Offset(5, 890));
      await tester.pumpAndSettle();
      expect(items(), hasLength(6), reason: 'closing the panel draws nothing');
      await drag(tester, [const Offset(400, 500), const Offset(480, 560)]);
      expect(item('new1')!['shape'], 'circle');
      // A tiny drag adds nothing.
      await drag(tester, [const Offset(600, 500), const Offset(601, 501)]);
      expect(items(), hasLength(7));
      // Edit as path for one selected shape: one step, then point editing.
      paper.select(ObjectSelection(['new0']));
      await tester.tap(byKey('draw-tool-shapes'));
      await tester.pumpAndSettle();
      expect(byKey('edit-as-path'), findsOneWidget);
      final steps = notes().stepsBack;
      await tester.tap(byKey('edit-as-path'));
      await tester.pumpAndSettle();
      expect(item('new0')!['shape'], 'path');
      expect(item('new0')!['nodes'], hasLength(4));
      expect(notes().stepsBack, steps + 1);
      expect(draw.pathEditing.value, 'new0');
      expect(draw.pathTarget, isNull, reason: 'a path is no geometric shape');
      await finish(tester);
    });

    testWidgets('the panel sets colors, the custom color and the preview', (
      tester,
    ) async {
      await pump(tester);
      await toDraw(tester);
      await tester.tap(byKey('draw-tool-round'));
      await tester.pumpAndSettle();
      expect(byKey('draw-settings'), findsOneWidget);
      expect(byKey('draw-preview'), findsOneWidget);
      expect(byKey('draw-tip-angle'), findsNothing);
      for (final (name, _) in const DrawSettings().colors) {
        expect(byKey('ink-color-$name'), findsOneWidget);
      }
      await tester.tap(byKey('ink-color-colorBlue'));
      await tester.pumpAndSettle();
      expect(draw.tools.pen(InkTool.round).color, '#3D5AFEFF');
      await tester.tap(byKey('ink-color-custom'));
      await tester.pumpAndSettle();
      expect(byKey('custom-color'), findsOneWidget);
      final hue = tester.getRect(byKey('custom-hue'));
      await tester.tapAt(Offset(hue.left + hue.width * 0.4, hue.bottom - 14));
      await tester.pumpAndSettle();
      final custom = draw.tools.pen(InkTool.round).color;
      expect(custom, isNot('#3D5AFEFF'));
      expect(isInkColor(custom), isTrue);
      expect(const DrawSettings().colors.any((c) => c.$2 == custom), isFalse);
      // The flat pen shows its tip angle.
      await tester.tapAt(const Offset(5, 890));
      await tester.pumpAndSettle();
      await tester.tap(byKey('draw-tool-flat'));
      await tester.pump();
      await tester.tap(byKey('draw-tool-flat'));
      await tester.pumpAndSettle();
      expect(byKey('draw-tip-angle'), findsOneWidget);
      await finish(tester);
    });

    // Review images for the manager (H7). Not golden checks: they are
    // written only when ANNOTATIONS_REVIEW_DIR is set.
    final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
    for (final brightness in Brightness.values) {
      final mode = brightness.name;
      Future<void> shot(WidgetTester tester, String name) async {
        await tester.pump();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('$review/draw_${name}_$mode.png'),
        );
      }

      Future<void> close(WidgetTester tester) async {
        await tester.tapAt(const Offset(5, 635));
        await tester.pumpAndSettle();
      }

      Future<void> panel(WidgetTester tester, DrawTool tool) async {
        if (draw.tools.active != tool) {
          await tester.tap(byKey('draw-tool-${tool.name}'));
          await tester.pump();
        }
        await tester.tap(byKey('draw-tool-${tool.name}'));
        await tester.pumpAndSettle();
      }

      testWidgets('review images, $mode', skip: review == null, (tester) async {
        debugDisableShadows = false;
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        await pump(tester, brightness: brightness, size: const Size(1000, 640));
        await shot(tester, 'mode_type');
        await toDraw(tester);
        // Marks of every pen, then the shapes.
        draw.change(const InkStyleChange(width: 3));
        await drag(tester, line(60, 420, length: 160));
        draw.selectTool(DrawTool.flat);
        await drag(tester, line(260, 420, length: 160));
        draw.selectTool(DrawTool.brush);
        await drag(tester, line(460, 420, length: 160));
        draw.selectTool(DrawTool.highlighter);
        await drag(tester, line(40, 116, length: 300));
        draw.selectTool(DrawTool.round);
        await shot(tester, 'mode_draw');
        for (final tool in [
          DrawTool.round,
          DrawTool.flat,
          DrawTool.brush,
          DrawTool.highlighter,
        ]) {
          await panel(tester, tool);
          await shot(tester, 'settings_${tool.name}');
          await close(tester);
        }
        await panel(tester, DrawTool.round);
        draw.change(const InkStyleChange(color: '#7B1FA2FF'));
        await tester.pump();
        await tester.tap(byKey('ink-color-custom'));
        await tester.pumpAndSettle();
        await shot(tester, 'colors_custom');
        await close(tester);
        draw.selectTool(DrawTool.shapes);
        for (final (kind, x) in [
          (ShapeKind.rectangle, 680.0),
          (ShapeKind.circle, 800.0),
          (ShapeKind.triangle, 880.0),
        ]) {
          draw.selectShape(kind);
          await drag(tester, [Offset(x, 400), Offset(x + 90, 470)]);
        }
        await tester.pumpAndSettle();
        await shot(tester, 'shapes');
        await panel(tester, DrawTool.shapes);
        await shot(tester, 'shapes_settings');
        await close(tester);
        paper.select(ObjectSelection(['box']));
        await panel(tester, DrawTool.shapes);
        await shot(tester, 'shapes_selected');
        await close(tester);
        await finish(tester);
        debugDisableShadows = true;
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}
