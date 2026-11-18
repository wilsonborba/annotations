// annotations#33: the view lock for every input kind, finger navigation,
// finger drawing, Focus and the view on keyboard and rotation (B8).
import 'dart:io';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/icons.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'paper_canvas_test.dart'
    show desktop, handlerFor, host, longNote, phone, setWindow;

Future<PaperHandler> open(
  WidgetTester tester, {
  Size size = desktop,
  ValueChanged<bool>? onFocus,
  Brightness brightness = Brightness.light,
}) async {
  await setWindow(tester, size);
  final handler = handlerFor(longNote(60));
  await tester.pumpWidget(
    host(
      PaperScreen(handler: handler, onFocusChanged: onFocus),
      brightness: brightness,
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(handler.dispose);
  // Away from the top, so every direction can move.
  handler.scrollBy(const Offset(0, 600));
  await tester.pump();
  return handler;
}

Offset center(WidgetTester tester) =>
    tester.getCenter(find.byKey(const Key('paper-layer-paper')));

Future<void> wheel(
  WidgetTester tester,
  Offset delta, {
  bool zoom = false,
}) async {
  final mouse = TestPointer(1, PointerDeviceKind.mouse);
  if (zoom) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendEventToBinding(mouse.hover(center(tester)));
  await tester.sendEventToBinding(mouse.scroll(delta));
  if (zoom) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> trackpad(
  WidgetTester tester, {
  Offset pan = Offset.zero,
  double scale = 1,
}) async {
  final pad = TestPointer(2, PointerDeviceKind.trackpad);
  final at = center(tester);
  await tester.sendEventToBinding(pad.panZoomStart(at));
  for (var i = 1; i <= 5; i++) {
    await tester.sendEventToBinding(
      pad.panZoomUpdate(at, pan: pan * (i / 5), scale: 1 + (scale - 1) * i / 5),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.sendEventToBinding(pad.panZoomEnd());
  await tester.pump();
}

Future<void> finger(WidgetTester tester, Offset by) async {
  final g = await tester.startGesture(
    center(tester),
    kind: PointerDeviceKind.touch,
  );
  for (var i = 0; i < 6; i++) {
    await g.moveBy(by / 6, timeStamp: Duration(milliseconds: 16 * (i + 1)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up(timeStamp: const Duration(milliseconds: 112));
  await tester.pump();
}

Future<void> pinch(WidgetTester tester) async {
  final c = center(tester);
  final a = await tester.startGesture(
    c - const Offset(40, 0),
    kind: PointerDeviceKind.touch,
  );
  final b = await tester.startGesture(
    c + const Offset(40, 0),
    kind: PointerDeviceKind.touch,
  );
  for (var i = 0; i < 6; i++) {
    await a.moveBy(const Offset(-12, 0));
    await b.moveBy(const Offset(12, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('initial state: unlocked, Focus off, fingers navigate, no '
      'finger drawing', (tester) async {
    final h = await open(tester);
    final preferences = Preferences();
    expect(h.locked, isFalse);
    expect(h.fingerNavigation, isTrue);
    expect(preferences.fingerNavigation, isTrue);
    expect(preferences.fingerDrawing, isFalse);
    expect(find.byKey(const Key('paper-status')), findsOneWidget);
    expect(find.byKey(const Key('toolbar-exit-focus')), findsNothing);
    final lock = tester.widget<AppIcon>(
      find.descendant(
        of: find.byKey(const Key('view-lock')),
        matching: find.byType(AppIcon),
      ),
    );
    expect(lock.icon, AppIcons.lockOpen);
  });

  group('a locked view does not move', () {
    for (final (name, input) in <(String, Future<void> Function(WidgetTester))>[
      ('mouse wheel', (t) => wheel(t, const Offset(0, 300))),
      ('wheel zoom', (t) => wheel(t, const Offset(0, -300), zoom: true)),
      ('trackpad pan', (t) => trackpad(t, pan: const Offset(0, -200))),
      ('trackpad pinch', (t) => trackpad(t, scale: 1.6)),
      ('touch scroll', (t) => finger(t, const Offset(0, -240))),
      ('touch pinch', pinch),
      (
        'momentum',
        (t) async {
          await t.flingFrom(center(t), const Offset(0, -300), 3000);
          await t.pumpAndSettle();
        },
      ),
      (
        'zoom keys',
        (t) async {
          await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await t.sendKeyEvent(LogicalKeyboardKey.equal);
          await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await t.pump();
        },
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await open(tester);
        // Unlocked, the input moves the view.
        final start = h.view.value;
        await input(tester);
        expect(h.view.value, isNot(start), reason: 'unlocked $name');
        await tester.tap(find.byKey(const Key('view-lock')));
        await tester.pump();
        expect(h.locked, isTrue);
        final locked = h.view.value;
        await input(tester);
        expect(h.view.value, locked, reason: 'locked $name');
      });
    }
  });

  testWidgets('a running fling stops when the view is locked', (tester) async {
    final h = await open(tester);
    await tester.flingFrom(center(tester), const Offset(0, -300), 3000);
    await tester.pump(const Duration(milliseconds: 50));
    h.locked = true;
    final at = h.view.value;
    await tester.pumpAndSettle();
    expect(h.view.value, at);
  });

  testWidgets('locked: writing goes on, edits and the toolbar room never move '
      'the paper; unlock by click and by keyboard', (tester) async {
    final h = await open(tester);
    await tester.tap(find.byKey(const Key('view-lock')));
    await tester.pump();
    final at = h.view.value;
    // A pen stroke in Draw mode.
    await tester.tap(find.byKey(const Key('mode-draw')));
    await tester.pump();
    final items = (h.document as PaperDocument).items.length;
    final pen = await tester.startGesture(
      center(tester),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 0; i < 8; i++) {
      await pen.moveBy(
        const Offset(12, 3),
        timeStamp: Duration(milliseconds: 16 * (i + 1)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pen.up(timeStamp: const Duration(milliseconds: 144));
    await tester.pump();
    expect((h.document as PaperDocument).items.length, items + 1);
    expect(h.view.value, at);
    // A keyboard or a toolbar that takes more room moves only the toolbar.
    h.toolbarInsets = const EdgeInsets.only(top: 140);
    expect(h.view.value, at);
    // Zoom buttons are off while locked.
    final zoomIn = tester.widget<TextButton>(
      find
          .descendant(
            of: find.byKey(const Key('paper-status')),
            matching: find.byType(TextButton),
          )
          .last,
    );
    expect(zoomIn.onPressed, isNull);
    // Unlock with the keyboard: the lock control takes the focus, Enter.
    Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(const Key('view-lock')),
          matching: find.byType(AppIcon),
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(h.locked, isFalse);
    expect(h.view.value?.zoom, at?.zoom);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('finger navigation off: fingers do not pan; trackpad, wheel and '
      'toolbar taps stay; the setting is kept', (tester) async {
    final h = await open(tester);
    await tester.tap(find.byKey(const Key('finger-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finger-navigation')));
    await tester.pumpAndSettle();
    expect(h.fingerNavigation, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => k.contains('fingerNavigation')), isTrue);
    final at = h.view.value;
    await finger(tester, const Offset(0, -240));
    await pinch(tester);
    expect(h.view.value, at);
    await trackpad(tester, pan: const Offset(0, -200));
    expect(h.view.value, isNot(at));
    final afterPad = h.view.value;
    await wheel(tester, const Offset(0, 200));
    expect(h.view.value, isNot(afterPad));
    // A toolbar tap with a finger still works.
    await tester.tap(find.byKey(const Key('mode-draw')));
    await tester.pump();
    expect(h.tool.name, 'draw');
  });

  testWidgets('finger drawing is its own setting, off at first', (
    tester,
  ) async {
    final h = await open(tester);
    await tester.tap(find.byKey(const Key('mode-draw')));
    await tester.pump();
    final items = (h.document as PaperDocument).items.length;
    await finger(tester, const Offset(120, 30));
    expect((h.document as PaperDocument).items.length, items);
    await tester.tap(find.byKey(const Key('finger-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finger-drawing')));
    await tester.pumpAndSettle();
    await finger(tester, const Offset(120, 30));
    expect((h.document as PaperDocument).items.length, items + 1);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Focus hides the status panel and keeps tools, the lock, '
      'selection, mode and view; it does not lock', (tester) async {
    final changes = <bool>[];
    final h = await open(tester, onFocus: changes.add);
    h.select(ObjectSelection(['t0']));
    await tester.tap(find.byKey(const Key('mode-draw')));
    await tester.pump();
    final at = h.view.value;
    await tester.tap(find.byKey(const Key('focus-start')));
    await tester.pump();
    expect(changes, [true]);
    expect(find.byKey(const Key('paper-status')), findsNothing);
    expect(find.byKey(const Key('paper-toolbar')), findsOneWidget);
    expect(find.byKey(const Key('mode-switch')), findsOneWidget);
    expect(find.byKey(const Key('view-lock')), findsOneWidget);
    expect(find.byKey(const Key('toolbar-exit-focus')), findsOneWidget);
    expect(h.locked, isFalse);
    expect(h.view.value, at);
    expect(h.tool.name, 'draw');
    expect(h.selection.value.ids, {'t0'});
    await tester.tap(find.byKey(const Key('toolbar-exit-focus')));
    await tester.pump();
    expect(changes, [true, false]);
    expect(find.byKey(const Key('paper-status')), findsOneWidget);
  });

  testWidgets('rotation keeps the zoom and the central page point', (
    tester,
  ) async {
    final h = await open(tester, size: phone);
    final before = h.view.value!;
    final middle = before.toPage(
      Offset(before.size.width, before.size.height) / 2,
    );
    await setWindow(tester, Size(phone.height, phone.width));
    await tester.pumpAndSettle();
    final after = h.view.value!;
    expect(after.zoom, before.zoom);
    final now = after.toPage(Offset(after.size.width, after.size.height) / 2);
    expect((now - middle).distance, lessThan(1));
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
        matchesGoldenFile('$review/view_${name}_$mode.png'),
      );
      final h = await open(tester, brightness: brightness);
      await shot('unlocked');
      await tester.tap(find.byKey(const Key('view-lock')));
      await tester.pump();
      await shot('locked');
      await tester.tap(find.byKey(const Key('finger-settings')));
      await tester.pumpAndSettle();
      await shot('finger_settings');
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('focus-start')));
      await tester.pump();
      await shot('focus_locked');
      h.locked = false;
      await tester.pump();
      await shot('focus');
      await tester.tap(find.byKey(const Key('toolbar-exit-focus')));
      await tester.pump();
      await open(tester, size: phone, brightness: brightness);
      await shot('phone');
    });
  }
}
