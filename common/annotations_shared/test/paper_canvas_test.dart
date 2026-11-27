import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:annotations_shared/core/local_store_settings.dart';
import 'package:annotations_shared/core/paper_settings.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/ink_outline.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/paper_page.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/paper_controls.dart';
import 'package:annotations_shared/presentation/frontend/components/save_state.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_layers.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:annotations_shared/domain/models/stroke_samples_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';
import 'note_autosave_test.dart' show SlowStore;

final schema = DocumentSchema('note-original', 1);

const phone = Size(390, 844);
const desktop = Size(1280, 900);

/// A wavy stroke from [x], [y] (page units), [length] long.
Map<String, Object?> stroke(
  String id,
  num x,
  num y, {
  num length = 260,
  num width = 3,
  String color = '#000000FF',
  int samples = 24,
}) {
  final xs = <int>[], ys = <int>[];
  for (var i = 0; i < samples; i++) {
    xs.add(((x + length * i / (samples - 1)) * 100).round());
    ys.add(((y + 10 * (i.isEven ? 0 : 1)) * 100).round());
  }
  return {
    'id': id,
    'kind': 'stroke',
    'tool': 'round',
    'brush_version': 1,
    'width': width,
    'color': color,
    'opacity': 1,
    'samples': SampleCodec.encode(
      SampleColumns(
        x: xs,
        y: ys,
        t: [for (var i = 0; i < samples; i++) i * 8],
        pressure: [for (var i = 0; i < samples; i++) 500],
        tilt: [for (var i = 0; i < samples; i++) 600],
      ),
    ),
    'nodes': [
      {
        'x': xs.first,
        'y': ys.first,
        'out': {'x': xs[2], 'y': ys[2]},
        'mode': 'smooth',
        'corner': false,
        'sample': 0,
      },
      {
        'x': xs.last,
        'y': ys.last,
        'in': {'x': xs[samples - 3], 'y': ys[samples - 3]},
        'mode': 'independent',
        'corner': true,
        'sample': samples - 1,
      },
    ],
  };
}

Map<String, Object?> text(
  String id,
  num x,
  num y,
  num w,
  num h,
  List<Map<String, Object?>> spans,
) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': w,
  'height': h,
  'spans': spans,
};

/// A study note with text, ink in two colors, a shape and an image block.
NoteDocument studyNote({Map<String, Object?>? background}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': background ?? {'kind': 'blank'},
      },
      'items': [
        text('title', 40, 40, 560, 48, [
          {'text': 'Photosynthesis', 'size': 32, 'bold': true},
        ]),
        text('body', 40, 112, 424, 120, [
          {'text': 'Plants turn light, water and carbon dioxide into '},
          {'text': 'glucose', 'bold': true, 'color': '#1E40AFFF'},
          {'text': ' and oxygen.\nIt happens in the chloroplasts.'},
        ]),
        stroke('ink1', 40, 260, length: 300, width: 4),
        stroke('ink2', 40, 300, length: 220, width: 6, color: '#DC2626FF'),
        {
          'id': 'box',
          'kind': 'shape',
          'shape': 'rectangle',
          'color': '#1E40AFFF',
          'line_width': 2,
          'opacity': 1,
          'x': 520,
          'y': 120,
          'width': 220,
          'height': 120,
          'fill': '#BFDBFE80',
        },
        {
          'id': 'img',
          'kind': 'image',
          'x': 600,
          'y': 304,
          'width': 304,
          'height': 180,
          'file_id': 'file-image-1',
        },
      ],
    }, schema: schema);

/// A long note: [rows] rows of text and ink down the page.
NoteDocument longNote(int rows) => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.5},
  },
  'items': [
    for (var r = 0; r < rows; r++) ...[
      text('t$r', 40, 40 + r * 120, 300, 40, [
        {'text': 'Row $r of the long note'},
      ]),
      stroke('a$r', 380, 50 + r * 120, length: 260),
      stroke('b$r', 680, 50 + r * 120, length: 260, color: '#DC2626FF'),
    ],
  ],
}, schema: schema);

String itemsJson(NoteDocument d) => jsonEncode(d.toJson()['items']);

/// A store that commits at once and keeps every saved draft.
final class MemoryStore implements LocalNoteStore {
  final saved = <LocalNoteDraft>[];
  final _slow = SlowStore();
  @override
  Future<LocalNote> save(LocalNoteDraft draft) {
    saved.add(draft);
    final f = _slow.save(draft);
    _slow.commit();
    return f;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PaperHandler handlerFor(
  NoteDocument document, {
  LocalNoteStore? store,
  LocalStoreSettings settings = const LocalStoreSettings(
    autosaveDelay: Duration(milliseconds: 20),
  ),
}) => PaperHandler(
  noteId: 'n1',
  document: document,
  autosave: NoteAutosave(store ?? MemoryStore(), settings: settings),
);

Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
    AppScope(
      preferences: Preferences(),
      service: fixtureService(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(brightness),
        home: Material(child: child),
      ),
    );

Future<void> setWindow(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// The pixels of the layer [key] as RGBA bytes.
Future<(ByteDataView, int)> layerPixels(WidgetTester tester, String key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(Key('paper-layer-$key')),
  );
  late ByteData data;
  late int width;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    width = image.width;
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return (ByteDataView(data), width);
}

final class ByteDataView {
  ByteDataView(this.data);
  final ByteData data;
  int rgba(int x, int y, int width) => data.getUint32((y * width + x) * 4);
}

Future<void> golden(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/paper/$name.png'),
  );
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('paper page (domain)', () {
    test('a background change keeps content, positions and collisions', () {
      const page = PaperPage();
      final before = studyNote();
      final rules = const EditorRules();
      // One move that collides and one that fits, before any change.
      final blocked = rules.move(before, ['body'], 500, 250).accepted;
      final free = rules.move(before, ['body'], 0, 1000).accepted;
      expect(blocked, isFalse);
      expect(free, isTrue);
      final layout = DocumentLayout.of(before)!;
      final bounds = layout.boundsOf(layout.units);
      for (final pattern in PaperPattern.values) {
        for (final spacing in [12, 24, 64]) {
          final handler = handlerFor(before);
          final guides = PaperGuides.pick(
            pattern,
          ).copyWith(spacing: spacing, visibility: 0.9);
          final decision = page.setGuides(handler.session, guides);
          expect(decision.accepted, isTrue, reason: '$pattern');
          final after = decision.document;
          expect(itemsJson(after), itemsJson(before));
          expect(page.guidesOf(after)!.pattern, pattern);
          final l = DocumentLayout.of(after)!;
          expect(l.boundsOf(l.units).toString(), bounds.toString());
          expect(rules.move(after, ['body'], 500, 250).accepted, blocked);
          expect(rules.move(after, ['body'], 0, 1000).accepted, free);
          handler.autosave.dispose();
        }
      }
    });

    test('the background is stored with the note', () async {
      final store = MemoryStore();
      final handler = handlerFor(studyNote(), store: store);
      handler.pickPattern(PaperPattern.dots);
      await handler.close();
      final page = store.saved.last.document.toJson()['page'] as Map;
      expect(page['background'], {
        'kind': 'dots',
        'spacing': 24,
        'visibility': 0.5,
      });
      expect(page['width'], 1000);
      // Back to blank drops spacing and visibility.
      handler.pickPattern(PaperPattern.blank);
      await handler.close();
      expect(
        (store.saved.last.document.toJson()['page'] as Map)['background'],
        {'kind': 'blank'},
      );
    });

    test('guides follow page coordinates, not the view', () {
      const page = PaperPage();
      const g = PaperGuides(PaperPattern.grid, spacing: 24, visibility: 0.5);
      final a = page.lines(
        g,
        width: 1000,
        left: 0,
        top: 0,
        right: 400,
        bottom: 300,
      );
      final b = page.lines(
        g,
        width: 1000,
        left: 100,
        top: 250,
        right: 1200,
        bottom: 600,
      );
      for (final v in [...a.rows, ...a.columns, ...b.rows, ...b.columns]) {
        expect(v % 24, 0);
      }
      expect(b.columns.last, lessThan(1000));
      expect(
        page
            .lines(
              PaperGuides.blank,
              width: 1000,
              left: 0,
              top: 0,
              right: 9,
              bottom: 9,
            )
            .rows,
        isEmpty,
      );
    });

    test('the page grows downward with its content', () {
      const page = PaperPage();
      final short = page.pageHeight(studyNote(), 1000);
      expect(short, 1000 * const PaperSettings().minPageRatio);
      final long = page.pageHeight(longNote(60), 1000);
      expect(
        long,
        greaterThan(60 * 120 + const PaperSettings().trailingSpace - 100),
      );
    });
  });

  group('view (handler)', () {
    test('content-job insertion is a stable ordinary text edit', () {
      final handler = handlerFor(studyNote());
      addTearDown(handler.dispose);
      final beforeCount = (handler.document as PaperDocument).items.length;

      expect(
        handler.insertContentJobText('job/one', 'Reviewed extracted text'),
        isTrue,
      );
      final after = handler.document as PaperDocument;
      expect(after.items, hasLength(beforeCount + 1));
      final inserted = after.items.last as TextItem;
      expect(inserted.id, startsWith('content-job-'));
      expect(
        inserted.spans.map((span) => span.text).join(),
        'Reviewed extracted text',
      );

      // A repeated Insert after a local persistence error cannot duplicate it.
      expect(
        handler.insertContentJobText('job/one', 'Reviewed extracted text'),
        isTrue,
      );
      expect(
        (handler.document as PaperDocument).items,
        hasLength(beforeCount + 1),
      );
      handler.undo();
      expect((handler.document as PaperDocument).items, hasLength(beforeCount));
    });

    test('zoom and pan never change the document', () {
      final note = studyNote();
      final handler = handlerFor(note);
      handler.layoutView(phone);
      final first = handler.view.value!;
      handler.zoomIn();
      handler.scrollBy(const Offset(40, 300));
      handler.zoomTo(2.5, focal: const Offset(100, 200));
      handler.layoutView(desktop);
      expect(identical(handler.document, note), isTrue);
      expect(handler.autosave.state.value, SaveState.saved);
      expect(handler.view.value, isNot(first));
    });

    test('a zoom keeps the page point under the focal point', () {
      final handler = handlerFor(longNote(30));
      handler.layoutView(desktop);
      handler.scrollBy(const Offset(0, 600));
      const focal = Offset(500, 400);
      final point = handler.view.value!.toPage(focal);
      handler.zoomTo(2, focal: focal);
      final after = handler.view.value!.toPage(focal);
      expect((after - point).distance, lessThan(1e-9));
    });

    test('a new window size keeps the zoom and the center point', () {
      final handler = handlerFor(longNote(30));
      handler.layoutView(desktop);
      handler.zoomTo(1.5);
      handler.scrollBy(const Offset(0, 900));
      final v = handler.view.value!;
      final center = v.toPage(Offset(v.size.width / 2, v.size.height / 2));
      handler.layoutView(const Size(1000, 700));
      final w = handler.view.value!;
      expect(w.zoom, v.zoom);
      final c2 = w.toPage(Offset(w.size.width / 2, w.size.height / 2));
      expect((c2 - center).distance, lessThan(1e-6));
    });

    test('no navigation during an active stroke or a locked view', () {
      final handler = handlerFor(longNote(30));
      handler.layoutView(phone);
      final v = handler.view.value!;
      handler.activeInk.value = const InkOutline([], '#000000FF', 1);
      expect(handler.scrollBy(const Offset(0, 100)), isFalse);
      handler.zoomIn();
      expect(handler.view.value, v);
      handler.activeInk.value = null;
      handler.locked = true;
      expect(handler.scrollBy(const Offset(0, 100)), isFalse);
      handler.locked = false;
      expect(handler.scrollBy(const Offset(0, 100)), isTrue);
    });
  });

  group('canvas', () {
    testWidgets('phone and desktop draw the same note at the same positions', (
      tester,
    ) async {
      final pixels = <Size, (ByteDataView, int, Offset)>{};
      for (final size in [phone, desktop]) {
        await setWindow(tester, size);
        final handler = handlerFor(studyNote());
        await tester.pumpWidget(host(PaperScreen(handler: handler)));
        await tester.pumpAndSettle();
        // The same zoom on both screens; only the view differs.
        handler.zoomTo(1, focal: Offset.zero);
        handler.scrollBy(const Offset(-10000, -10000));
        await tester.pumpAndSettle();
        await golden(
          tester,
          'paper_${size == phone ? 'phone' : 'desktop'}_light',
        );
        final (data, width) = await layerPixels(tester, 'content');
        final origin = handler.view.value!.toScreen(Offset.zero);
        pixels[size] = (data, width, origin);
        await tester.pumpWidget(const SizedBox());
        handler.dispose();
      }
      // Compare the page area that both screens show, pixel by pixel.
      final (p, pw, po) = pixels[phone]!;
      final (d, dw, dor) = pixels[desktop]!;
      expect(po.dx, po.dx.roundToDouble());
      expect(dor.dx, dor.dx.roundToDouble());
      var inked = 0;
      // Toolbar clearance changes the visible page region on narrow screens.
      // Compare every shared visible pixel, without sampling past either image.
      final sharedHeight = [
        700,
        p.data.lengthInBytes ~/ (pw * 4) - po.dy.round(),
        d.data.lengthInBytes ~/ (dw * 4) - dor.dy.round(),
      ].reduce((a, b) => a < b ? a : b);
      final sharedWidth = [
        360,
        pw - po.dx.round(),
        dw - dor.dx.round(),
      ].reduce((a, b) => a < b ? a : b);
      expect(sharedHeight, greaterThan(0));
      expect(sharedWidth, greaterThan(0));
      for (var y = 0; y < sharedHeight; y++) {
        for (var x = 0; x < sharedWidth; x++) {
          final a = p.rgba(x + po.dx.round(), y + po.dy.round(), pw);
          final b = d.rgba(x + dor.dx.round(), y + dor.dy.round(), dw);
          if (a != b) fail('pixel $x,$y differs: $a vs $b');
          if (a != 0) inked++;
        }
      }
      expect(inked, greaterThan(1000));
    });

    for (final brightness in Brightness.values) {
      for (final pattern in PaperPattern.values) {
        testWidgets('background ${pattern.code}, ${brightness.name}', (
          tester,
        ) async {
          await setWindow(tester, desktop);
          final handler = handlerFor(
            studyNote(background: PaperGuides.pick(pattern).toJson()),
          );
          await tester.pumpWidget(
            host(PaperScreen(handler: handler), brightness: brightness),
          );
          await tester.pumpAndSettle();
          await golden(tester, 'paper_${brightness.name}_${pattern.code}');
          handler.dispose();
        });
      }
    }

    testWidgets('ink colors stay the same in light and dark', (tester) async {
      final colors = <Brightness, (int, int)>{};
      for (final b in Brightness.values) {
        await setWindow(tester, desktop);
        final handler = handlerFor(studyNote());
        await tester.pumpWidget(
          host(PaperScreen(handler: handler), brightness: b),
        );
        await tester.pumpAndSettle();
        handler.zoomTo(2, focal: Offset.zero);
        await tester.pumpAndSettle();
        // A point inside the 6 unit red stroke and a point of plain paper.
        final v = handler.view.value!;
        final ink = v.toScreen(const Offset(40 + 220 * 4 / 23, 300));
        final paper = v.toScreen(const Offset(900, 60));
        final (c, cw) = await layerPixels(tester, 'content');
        final (p, pw) = await layerPixels(tester, 'paper');
        colors[b] = (
          c.rgba(ink.dx.round(), ink.dy.round(), cw),
          p.rgba(paper.dx.round(), paper.dy.round(), pw),
        );
        await tester.pumpWidget(const SizedBox());
        handler.dispose();
      }
      final (lightInk, lightPaper) = colors[Brightness.light]!;
      final (darkInk, darkPaper) = colors[Brightness.dark]!;
      expect(lightInk, 0xDC2626FF);
      expect(darkInk, lightInk);
      expect(darkPaper, isNot(lightPaper));
    });

    testWidgets('borders show only on hover or selection', (tester) async {
      await setWindow(tester, desktop);
      final handler = handlerFor(studyNote());
      await tester.pumpWidget(host(PaperScreen(handler: handler)));
      await tester.pumpAndSettle();
      expect(handler.hover.value, isNull);
      expect(handler.selection.value.isEmpty, isTrue);
      await golden(tester, 'paper_frames_none_light');

      final v = handler.view.value!;
      // Type mode hovers blocks; ink and shapes are transparent there (B2.4).
      final onBox = v.toScreen(const Offset(700, 380));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(onBox);
      await tester.pump();
      expect(handler.hover.value, 'img');
      handler.select(ObjectSelection(['img']));
      await tester.pump();
      await golden(tester, 'paper_frames_mouse_light');

      // Touch has no hover; its handles are larger.
      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(handler.hover.value, isNull);
      final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
      await touch.down(v.toScreen(const Offset(700, 380)));
      await tester.pump();
      expect(handler.pointer.value, PointerDeviceKind.touch);
      expect(handler.hover.value, isNull);
      await touch.up();
      await tester.pumpAndSettle();
      await golden(tester, 'paper_frames_touch_light');
      handler.dispose();
    });

    testWidgets('only the active stroke layer repaints while drawing', (
      tester,
    ) async {
      await setWindow(tester, desktop);
      final handler = handlerFor(longNote(40));
      await tester.pumpWidget(host(PaperScreen(handler: handler)));
      await tester.pumpAndSettle();
      paperPaintCounts.clear();
      final live = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [stroke('live', 100, 200, length: 400)],
      }, schema: schema);
      final sample = strokeOutline(
        (live as PaperDocument).items.single as StrokeItem,
      )!;
      for (var i = 0; i < 30; i++) {
        handler.activeInk.value = InkOutline(
          sample.pieces.take(1 + i % sample.pieces.length).toList(),
          sample.color,
          sample.opacity,
        );
        await tester.pump();
      }
      expect(paperPaintCounts['active'], 30);
      expect(paperPaintCounts['content'], isNull);
      expect(paperPaintCounts['paper'], isNull);
      expect(paperPaintCounts['frame'], isNull);
      handler.dispose();
    });
  });

  group('performance', () {
    testWidgets('frame times on a long note', (tester) async {
      await setWindow(tester, desktop);
      // 400 rows: 1200 items on a page about 48 000 units long.
      final note = longNote(400);
      final handler = handlerFor(note);
      await tester.pumpWidget(host(PaperScreen(handler: handler)));
      await tester.pumpAndSettle();
      handler.zoomTo(1, focal: Offset.zero);
      handler.scrollBy(const Offset(0, 20000));
      await tester.pumpAndSettle();
      final live = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [stroke('live', 100, 20200, length: 600, samples: 200)],
      }, schema: schema);
      final outline = strokeOutline(
        (live as PaperDocument).items.single as StrokeItem,
      )!;

      Future<List<int>> frames(int n, FutureOr<void> Function(int) step) async {
        final out = <int>[];
        for (var i = 0; i < n; i++) {
          final watch = Stopwatch()..start();
          await step(i);
          await tester.pump();
          out.add(watch.elapsedMicroseconds);
        }
        out.sort();
        return out;
      }

      String report(List<int> us) {
        double ms(int v) => v / 1000;
        final median = us[us.length ~/ 2];
        final p95 = us[(us.length * 0.95).floor()];
        return 'median ${ms(median).toStringAsFixed(2)} ms, '
            'p95 ${ms(p95).toStringAsFixed(2)} ms, '
            'max ${ms(us.last).toStringAsFixed(2)} ms';
      }

      paperPaintCounts.clear();
      final drawing = await frames(200, (i) {
        handler.activeInk.value = InkOutline(
          outline.pieces.take(1 + i * outline.pieces.length ~/ 200).toList(),
          outline.color,
          outline.opacity,
        );
      });
      expect(paperPaintCounts.keys, ['active']);
      handler.activeInk.value = null;
      await tester.pump();
      final panning = await frames(
        200,
        (i) => handler.scrollBy(Offset(0, i.isEven ? 7 : -5)),
      );
      // ignore: avoid_print
      print(
        'long note, ${(note as PaperDocument).items.length} items, '
        'page ${handler.pageHeight.round()} units, ${desktop.width.round()}x'
        '${desktop.height.round()} window (flutter_tester, build+layout+paint, '
        'no GPU raster):\n'
        '  drawing (active stroke layer only): ${report(drawing)}\n'
        '  panning (all layers repaint): ${report(panning)}',
      );
      handler.dispose();
    });
  });

  group('save state', () {
    testWidgets('Saved appears only after the store commit', (tester) async {
      await setWindow(tester, desktop);
      final store = SlowStore();
      final handler = handlerFor(studyNote(), store: store);
      await tester.pumpWidget(host(PaperScreen(handler: handler)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('save-state-saved')), findsOneWidget);

      handler.pickPattern(PaperPattern.grid);
      await tester.pump();
      expect(find.byKey(const Key('save-state-saving')), findsOneWidget);
      // The pause ends and the slow store is still writing.
      await tester.pump(const Duration(milliseconds: 50));
      expect(store.calls, hasLength(1));
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('save-state-saving')), findsOneWidget);
      expect(find.byKey(const Key('save-state-saved')), findsNothing);
      await golden(tester, 'save_saving_light');

      store.commit();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const Key('save-state-saved')), findsOneWidget);
      handler.dispose();
    });

    testWidgets('a failed save shows Retry, and Retry saves again', (
      tester,
    ) async {
      await setWindow(tester, desktop);
      final store = SlowStore();
      final handler = handlerFor(studyNote(), store: store);
      await tester.pumpWidget(host(PaperScreen(handler: handler)));
      await tester.pumpAndSettle();
      handler.pickPattern(PaperPattern.ruled);
      await tester.pump(const Duration(milliseconds: 50));
      store.fail();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const Key('save-state-failed')), findsOneWidget);
      expect(find.byKey(const Key('save-retry')), findsOneWidget);
      await golden(tester, 'save_failed_light');

      await tester.tap(find.byKey(const Key('save-retry')));
      await tester.pump();
      expect(find.byKey(const Key('save-state-saving')), findsOneWidget);
      expect(store.calls, hasLength(1));
      expect(
        (store.calls.single.$1.document.toJson()['page'] as Map)['background'],
        containsPair('kind', 'ruled'),
      );
      store.commit();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const Key('save-state-saved')), findsOneWidget);
      handler.dispose();
    });

    for (final brightness in Brightness.values) {
      testWidgets('save states and paper panel, ${brightness.name}', (
        tester,
      ) async {
        await setWindow(tester, const Size(520, 560));
        await tester.pumpWidget(
          host(
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in SaveState.values) ...[
                    SaveStateView(state: s, onRetry: () {}),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  PaperBackgroundPanel(
                    guides: PaperGuides.pick(PaperPattern.grid),
                    onPick: (_) {},
                    onPreview: (_) {},
                    onCommit: (_) {},
                  ),
                ],
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        await golden(tester, 'save_states_${brightness.name}');
      });
    }
  });
}
