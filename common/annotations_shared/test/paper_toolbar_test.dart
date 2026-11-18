// The editor toolbar (annotations#31): one widget test per B7 rule and
// behavior, plus long-press names on touch.
import 'dart:io';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/models/toolbar_placement.dart';
import 'package:annotations_shared/domain/services/draw_tools.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/handlers/draw_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/point_edit_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/text_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'draw_modes_test.dart' show drawNote;
import 'fixtures.dart';
import 'paper_canvas_test.dart' show handlerFor, setWindow;

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late PaperHandler paper;
  late TextHandler texts;
  late DrawHandler draw;
  late PointEditHandler points;
  late Preferences preferences;

  Future<void> pump(
    WidgetTester tester, {
    NoteDocument? document,
    Size size = const Size(1280, 900),
    Brightness brightness = Brightness.light,
  }) async {
    await setWindow(tester, size);
    paper = handlerFor(document ?? drawNote());
    preferences = Preferences();
    await preferences.load();
    texts = TextHandler(paper: paper, preferences: preferences);
    draw = DrawHandler(
      paper: paper,
      preferences: preferences,
      onDrawMode: texts.end,
    );
    points = PointEditHandler(draw: draw);
    addTearDown(texts.dispose);
    addTearDown(points.dispose);
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
          home: Material(
            child: PaperScreen(
              handler: paper,
              text: texts,
              draw: draw,
              points: points,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder byKey(String key) => find.byKey(Key(key));

  Alignment place(WidgetTester tester) =>
      tester.widget<Align>(byKey('toolbar-place')).alignment as Alignment;

  Axis axis(WidgetTester tester) => tester
      .widget<Flex>(
        find
            .descendant(of: byKey('paper-toolbar'), matching: find.byType(Flex))
            .first,
      )
      .direction;

  Future<void> finish(WidgetTester tester) async {
    texts.end();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> toDraw(WidgetTester tester) async {
    await tester.tap(byKey('mode-draw'));
    await tester.pump();
  }

  testWidgets('rule 1: it starts at the top', (tester) async {
    await pump(tester);
    expect(place(tester), Alignment.topCenter);
    expect(axis(tester), Axis.horizontal);
    await tester.pump();
    // The page starts below the docked toolbar, so nothing is hidden.
    final toolbar = tester.getRect(byKey('paper-toolbar'));
    expect(
      paper.view.value!.toScreen(Offset.zero).dy,
      greaterThan(toolbar.bottom),
    );
    await finish(tester);
  });

  testWidgets('rule 2: the position menu docks at every edge or floats', (
    tester,
  ) async {
    await pump(tester);
    for (final (edge, align, dir) in const [
      (ToolbarEdge.left, Alignment.centerLeft, Axis.vertical),
      (ToolbarEdge.right, Alignment.centerRight, Axis.vertical),
      (ToolbarEdge.bottom, Alignment.bottomCenter, Axis.horizontal),
      (ToolbarEdge.top, Alignment.topCenter, Axis.horizontal),
    ]) {
      await tester.tap(byKey('toolbar-position'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('toolbar-at-${edge.name}'));
      await tester.pumpAndSettle();
      expect(place(tester), align, reason: edge.name);
      expect(axis(tester), dir, reason: edge.name);
    }
    await finish(tester);
  });

  testWidgets('rule 2: the move handle floats it and docks it near an edge', (
    tester,
  ) async {
    await pump(tester);
    final handle = tester.getCenter(byKey('toolbar-move'));
    await tester.dragFrom(handle, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(preferences.toolbar.edge, ToolbarEdge.floating);
    // Tool buttons are not a drag handle: dragging one does not move it.
    final before = tester.getTopLeft(byKey('paper-toolbar'));
    await tester.drag(byKey('mode-type'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(byKey('paper-toolbar')), before);
    // A drop near the right edge docks there.
    await tester.dragFrom(
      tester.getCenter(byKey('toolbar-move')),
      Offset(1270.0 - tester.getCenter(byKey('toolbar-move')).dx, 0),
    );
    await tester.pumpAndSettle();
    expect(preferences.toolbar.edge, ToolbarEdge.right);
    await finish(tester);
  });

  testWidgets('rule 3: the controls follow the mode and the selection', (
    tester,
  ) async {
    await pump(tester);
    expect(byKey('draw-tool-round'), findsNothing, reason: 'Type mode');
    await toDraw(tester);
    for (final tool in DrawTool.values) {
      expect(
        byKey('draw-tool-${tool.name}'),
        findsOneWidget,
        reason: tool.name,
      );
    }
    expect(byKey('edit-points'), findsNothing);
    paper.select(ObjectSelection(['ink1']));
    await tester.pump();
    expect(byKey('edit-points'), findsOneWidget);
    await tester.tap(byKey('edit-points'));
    await tester.pump();
    expect(byKey('point-edit-panel'), findsOneWidget);
    expect(byKey('draw-tool-round'), findsNothing);
    await finish(tester);
  });

  testWidgets('the selection tool selects the drawing under the pointer', (
    tester,
  ) async {
    await pump(tester);
    await toDraw(tester);
    await tester.tap(byKey('draw-tool-select'));
    await tester.pump();
    await tester.tapAt(paper.view.value!.toScreen(const Offset(190, 262)));
    await tester.pump();
    expect(paper.selection.value.ids, ['ink1']);
    await tester.tapAt(paper.view.value!.toScreen(const Offset(700, 700)));
    await tester.pump();
    expect(paper.selection.value.isEmpty, isTrue);
    await finish(tester);
  });

  testWidgets('rule 4: tapping the active tool opens its settings', (
    tester,
  ) async {
    await pump(tester);
    await toDraw(tester);
    await tester.tap(byKey('draw-tool-round'));
    await tester.pumpAndSettle();
    expect(byKey('draw-settings'), findsOneWidget);
    // Rule 5 (outside tap): closes without drawing.
    final count = (paper.document.toJson()['items'] as List).length;
    await tester.tapAt(const Offset(640, 700));
    await tester.pumpAndSettle();
    expect(byKey('draw-settings'), findsNothing);
    expect((paper.document.toJson()['items'] as List).length, count);
    await finish(tester);
  });

  testWidgets('rule 6: collapse keeps the active tool and the danger mark', (
    tester,
  ) async {
    await pump(tester);
    await toDraw(tester);
    draw.selectTool(DrawTool.eraser);
    draw.setDangerous(true);
    await tester.pump();
    await tester.tap(byKey('toolbar-collapse'));
    await tester.pump();
    expect(byKey('toolbar-expand'), findsOneWidget);
    expect(byKey('draw-tool-eraser'), findsOneWidget);
    expect(byKey('draw-tool-round'), findsNothing);
    expect(byKey('toolbar-danger'), findsOneWidget);
    expect(byKey('eraser-danger-state'), findsOneWidget);
    await tester.tap(byKey('toolbar-expand'));
    await tester.pump();
    expect(byKey('draw-tool-round'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('rule 7: the placement is kept on this device', (tester) async {
    await pump(tester);
    await tester.tap(byKey('toolbar-position'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('toolbar-at-left'));
    await tester.pumpAndSettle();
    final again = Preferences();
    await again.load();
    expect(again.toolbar.edge, ToolbarEdge.left);
    await finish(tester);
  });

  testWidgets('rule 8: the keyboard moves it up and it comes back', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(byKey('toolbar-position'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('toolbar-at-bottom'));
    await tester.pumpAndSettle();
    final bottom = tester.getBottomLeft(byKey('paper-toolbar')).dy;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    final up = tester.getBottomLeft(byKey('paper-toolbar')).dy;
    expect(up, lessThanOrEqualTo(900 - 300));
    tester.view.resetViewInsets();
    await tester.pump();
    expect(tester.getBottomLeft(byKey('paper-toolbar')).dy, bottom);
    expect(preferences.toolbar.edge, ToolbarEdge.bottom);
    await finish(tester);
  });

  testWidgets('a floating toolbar stays inside the screen after a resize', (
    tester,
  ) async {
    await pump(tester);
    await preferences.saveToolbar(
      const ToolbarPlacement(edge: ToolbarEdge.floating, x: 1, y: 1),
    );
    await pump(tester, size: const Size(700, 500));
    final r = tester.getRect(byKey('paper-toolbar'));
    expect(r.right, lessThanOrEqualTo(700));
    expect(r.bottom, lessThanOrEqualTo(500));
    await finish(tester);
  });

  testWidgets('narrow screens: More keeps the active tool visible', (
    tester,
  ) async {
    await pump(tester, size: const Size(420, 800));
    await toDraw(tester);
    expect(byKey('toolbar-more'), findsOneWidget);
    draw.selectTool(DrawTool.select);
    await tester.pump();
    expect(byKey('draw-tool-select'), findsOneWidget);
    await tester.tap(byKey('toolbar-more'));
    await tester.pumpAndSettle();
    final hidden = DrawTool.values.firstWhere(
      (t) => tester.any(byKey('toolbar-more-${t.name}')),
    );
    await tester.tap(byKey('toolbar-more-${hidden.name}'));
    await tester.pumpAndSettle();
    expect(draw.tools.active, hidden);
    expect(byKey('draw-tool-${hidden.name}'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Notes has Undo and Redo; Instant has neither', (tester) async {
    await pump(tester);
    await toDraw(tester);
    expect(byKey('toolbar-undo'), findsOneWidget);
    draw.selectTool(DrawTool.eraser);
    await tester.pump();
    await tester.dragFrom(
      paper.view.value!.toScreen(const Offset(190, 240)),
      const Offset(0, 40),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(paper.canUndo, isTrue);
    await tester.tap(byKey('toolbar-undo'));
    await tester.pump();
    expect(paper.canRedo, isTrue);
    await tester.tap(byKey('toolbar-redo'));
    await tester.pump();
    expect(paper.canUndo, isTrue);
    await finish(tester);
    final room = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [],
    }, schema: DocumentSchema('instant-room', 1));
    await pump(tester, document: room);
    expect(byKey('toolbar-undo'), findsNothing);
    expect(byKey('toolbar-redo'), findsNothing);
    await finish(tester);
  });

  testWidgets('touch: a long press shows the name and runs nothing', (
    tester,
  ) async {
    await pump(tester);
    await toDraw(tester);
    final g = await tester.startGesture(
      tester.getCenter(byKey('draw-tool-flat')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Flat pen'), findsOneWidget);
    expect(draw.tools.active, DrawTool.round, reason: 'the tool did not run');
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Flat pen'), findsNothing);
    expect(draw.tools.active, DrawTool.round);
    await finish(tester);
  });

  // Review images for the manager (ANNOTATIONS_REVIEW_DIR).
  final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
  for (final (mode, brightness) in const [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    testWidgets('review images, $mode', skip: review == null, (tester) async {
      Future<void> shot(String name) => expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$review/toolbar_${name}_$mode.png'),
      );
      await pump(tester, brightness: brightness, size: const Size(1000, 640));
      await shot('type_top');
      await toDraw(tester);
      await shot('draw_top');
      await tester.tap(byKey('toolbar-position'));
      await tester.pumpAndSettle();
      await shot('position_menu');
      await tester.tap(byKey('toolbar-at-left'));
      await tester.pumpAndSettle();
      await shot('draw_left');
      draw.selectTool(DrawTool.eraser);
      draw.setDangerous(true);
      await tester.pump();
      if (tester.any(byKey('toolbar-collapse'))) {
        await tester.tap(byKey('toolbar-collapse'));
      } else {
        // A short side keeps Collapse in the position menu.
        await tester.tap(byKey('toolbar-position'));
        await tester.pumpAndSettle();
        await tester.tap(byKey('toolbar-collapse-entry'));
      }
      await tester.pumpAndSettle();
      await shot('collapsed_danger');
      await tester.tap(byKey('toolbar-expand'));
      draw.selectTool(DrawTool.round);
      await tester.pump();
      await pump(tester, brightness: brightness, size: const Size(420, 640));
      await toDraw(tester);
      await shot('narrow_more');
      await finish(tester);
    });
  }
}
