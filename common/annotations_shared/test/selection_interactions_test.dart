// annotations#32: selection, move, resize, grouping, the object actions and
// the Undo notice on the paper.
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'paper_canvas_test.dart'
    show desktop, handlerFor, host, setWindow, studyNote;

Map<String, Object?> item(PaperHandler h, String id) =>
    (h.document as PaperDocument).itemsJson.firstWhere((i) => i['id'] == id);

Future<PaperHandler> open(
  WidgetTester tester, [
  NoteDocument? doc,
  Brightness brightness = Brightness.light,
]) async {
  await setWindow(tester, desktop);
  final handler = handlerFor(doc ?? studyNote());
  await tester.pumpWidget(
    host(PaperScreen(handler: handler), brightness: brightness),
  );
  await tester.pumpAndSettle();
  addTearDown(handler.dispose);
  return handler;
}

Offset screen(PaperHandler h, double x, double y) =>
    h.view.value!.toScreen(Offset(x, y));

/// A mouse drag in small steps, so the move shows on the way.
Future<TestGesture> drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  bool release = true,
}) async {
  final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  for (var i = 1; i <= 8; i++) {
    await mouse.moveTo(Offset.lerp(from, to, i / 8)!);
    await tester.pump();
  }
  if (release) {
    await mouse.up();
    await tester.pump();
  }
  return mouse;
}

Future<void> click(WidgetTester tester, Offset at) async {
  final mouse = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await mouse.up();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a click selects a block, Shift adds one, empty paper clears', (
    tester,
  ) async {
    final h = await open(tester);
    await click(tester, screen(h, 700, 380));
    expect(h.selection.value.ids, {'img'});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, screen(h, 100, 60));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(h.selection.value.ids, {'img', 'title'});
    await click(tester, screen(h, 900, 700));
    expect(h.selection.value.isEmpty, isTrue);
    // With nothing selected, a click on text still opens it (annotations#27).
    await click(tester, screen(h, 100, 60));
    expect(h.editingText, 'title');
  });

  testWidgets('a box on empty paper selects the blocks inside it', (
    tester,
  ) async {
    final h = await open(tester);
    await drag(tester, screen(h, 560, 290), screen(h, 960, 520));
    expect(h.selection.value.ids, {'img'});
    // Ink is not selected by a box in Type mode (B2.4).
    await drag(tester, screen(h, 10, 20), screen(h, 990, 600));
    expect(h.selection.value.ids, {'title', 'body', 'img'});
  });

  testWidgets('a move shows the proposal and commits on release; one Undo '
      'restores it', (tester) async {
    final h = await open(tester);
    final before = jsonEncode(h.document.toJson());
    final mouse = await drag(
      tester,
      screen(h, 700, 380),
      screen(h, 700, 580),
      release: false,
    );
    // Not stored while dragging.
    expect(jsonEncode(h.document.toJson()), before);
    expect(find.byKey(const Key('selection-layer')), findsOneWidget);
    await mouse.up();
    await tester.pump();
    expect(item(h, 'img')['y'], 504);
    expect(item(h, 'img')['x'], 600);
    h.undo();
    await tester.pump();
    expect(jsonEncode(h.document.toJson()), before);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('an invalid drop shows red and keeps the old position', (
    tester,
  ) async {
    final h = await open(tester);
    final before = jsonEncode(h.document.toJson());
    // Onto the body text: an overlap of two blocks.
    await drag(tester, screen(h, 700, 380), screen(h, 240, 260));
    expect(jsonEncode(h.document.toJson()), before);
    expect(item(h, 'img')['x'], 600);
    expect(item(h, 'img')['y'], 304);
    expect(h.canUndo, isFalse);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a corner handle resizes; an overlap is rejected', (
    tester,
  ) async {
    final h = await open(tester);
    h.select(ObjectSelection(['img']));
    await tester.pump();
    // The bottom right corner, a little wider: the image keeps its shape.
    await drag(tester, screen(h, 904, 484), screen(h, 960, 520));
    expect(item(h, 'img')['width'], greaterThan(304));
    final width = item(h, 'img')['width'] as num;
    // The top left corner into the body text: rejected.
    await drag(tester, screen(h, 600, 304), screen(h, 300, 150));
    expect(item(h, 'img')['width'], width);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keys: select all, duplicate, arrows, group, ungroup, delete', (
    tester,
  ) async {
    final h = await open(tester);
    await click(tester, screen(h, 700, 380));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(item(h, 'img')['y'], 312);
    await shortcut(tester, LogicalKeyboardKey.keyD);
    final copy = h.selection.value.ids.single;
    expect(copy, isNot('img'));
    expect(item(h, copy)['kind'], 'image');
    await shortcut(tester, LogicalKeyboardKey.keyA);
    expect(h.selection.value.ids, containsAll(['title', 'body', 'img', copy]));
    h.select(ObjectSelection(['img', copy]));
    await shortcut(tester, LogicalKeyboardKey.keyG);
    final group = h.selection.value.ids.single;
    expect(item(h, group)['kind'], 'group');
    await shortcut(tester, LogicalKeyboardKey.keyG, shift: true);
    expect(h.selection.value.ids, {'img', copy});
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(
      (h.document as PaperDocument).itemsJson.where((i) => i['id'] == 'img'),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Undo and Redo show a short notice with the steps', (
    tester,
  ) async {
    final h = await open(tester);
    await click(tester, screen(h, 700, 380));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await shortcut(tester, LogicalKeyboardKey.keyZ);
    expect(find.text('Undo: 1 step back, 1 step forward'), findsOneWidget);
    await shortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(find.text('Redo: 2 steps back, 0 steps forward'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byKey(const Key('history-notice')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('history-notice')), findsNothing);
  });

  testWidgets('touch: a hold selects, taps add, the menu shows; a drag pans', (
    tester,
  ) async {
    final h = await open(tester);
    final scroll = h.view.value!.scroll;
    final pan = await tester.startGesture(
      screen(h, 700, 380),
      kind: PointerDeviceKind.touch,
    );
    await pan.moveBy(const Offset(0, -40));
    await pan.moveBy(const Offset(0, -40));
    await pan.up();
    await tester.pumpAndSettle();
    expect(h.selection.value.isEmpty, isTrue);
    expect(h.view.value!.scroll, isNot(scroll));

    final hold = await tester.startGesture(
      screen(h, 700, 380),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await tester.pump();
    expect(h.selection.value.ids, {'img'});
    expect(find.byKey(const Key('selection-menu')), findsOneWidget);
    await tester.tapAt(screen(h, 100, 60), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.selection.value.ids, {'img', 'title'});
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('selection-menu')),
        matching: find.byKey(const Key('selection-duplicate')),
      ),
    );
    await tester.pump();
    expect(h.selection.value.ids, hasLength(2));
    expect(h.selection.value.ids, isNot(contains('img')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('toolbar controls move and size without a drag', (tester) async {
    final h = await open(tester);
    await click(tester, screen(h, 700, 380));
    await tester.tap(find.byKey(const Key('selection-move-right')));
    await tester.pump();
    expect(item(h, 'img')['x'], 608);
    await tester.tap(find.byKey(const Key('selection-wider')));
    await tester.pump();
    expect(item(h, 'img')['width'], 312);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Draw mode: a lasso selects drawings and a drag moves them', (
    tester,
  ) async {
    final h = await open(tester);
    await tester.tap(find.byKey(const Key('mode-draw')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('draw-tool-select')));
    await tester.pump();
    // A loop around the black stroke (ink1, from x 40 to 340 at y 260).
    final mouse = await tester.startGesture(
      screen(h, 20, 240),
      kind: PointerDeviceKind.mouse,
    );
    for (final (x, y) in [
      (200, 236),
      (370, 240),
      (370, 282),
      (200, 284),
      (20, 280),
      (18, 244),
    ]) {
      await mouse.moveTo(screen(h, x.toDouble(), y.toDouble()));
      await tester.pump();
    }
    await mouse.up();
    await tester.pump();
    expect(h.selection.value.ids, {'ink1'});
    final before = item(h, 'ink1')['samples'];
    await drag(tester, screen(h, 190, 262), screen(h, 190, 462));
    expect(item(h, 'ink1')['samples'], isNot(before));
    expect(h.canUndo, isTrue);
    await tester.pump(const Duration(seconds: 1));
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
        matchesGoldenFile('$review/selection_${name}_$mode.png'),
      );
      final h = await open(tester, null, brightness);
      await click(tester, screen(h, 700, 380));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await click(tester, screen(h, 100, 60));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await shot('two_selected_toolbar');
      await click(tester, screen(h, 700, 380));
      await shot('one_selected_toolbar');
      var g = await drag(
        tester,
        screen(h, 700, 380),
        screen(h, 700, 600),
        release: false,
      );
      await shot('move_valid');
      await g.moveTo(screen(h, 300, 250));
      await tester.pump();
      await shot('move_invalid');
      await g.up();
      await tester.pump();
      await shot('drop_rejected');
      await tester.pump(const Duration(seconds: 1));
      g = await drag(
        tester,
        screen(h, 904, 484),
        screen(h, 960, 540),
        release: false,
      );
      await shot('resize');
      await g.up();
      await tester.pump();
      g = await drag(
        tester,
        screen(h, 520, 600),
        screen(h, 980, 760),
        release: false,
      );
      await shot('box');
      await g.up();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await shortcut(tester, LogicalKeyboardKey.keyZ);
      await shot('undo_notice');
      await tester.pump(const Duration(seconds: 3));
      final hold = await tester.startGesture(
        screen(h, 700, 380),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await hold.up();
      await tester.pump();
      await shot('touch_menu');
      await tester.tap(find.byKey(const Key('mode-draw')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('draw-tool-select')));
      await tester.pump();
      final mouse = await tester.startGesture(
        screen(h, 20, 240),
        kind: PointerDeviceKind.mouse,
      );
      for (final (x, y) in [(200, 236), (370, 240), (370, 282), (200, 284)]) {
        await mouse.moveTo(screen(h, x.toDouble(), y.toDouble()));
        await tester.pump();
      }
      await shot('lasso');
      await mouse.up();
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
