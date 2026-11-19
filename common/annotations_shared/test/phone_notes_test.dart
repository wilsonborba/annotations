// annotations#35: phones write simple typed notes and read everything else
// without changing it.
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/note_views.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/typed_note_handler.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:annotations_shared/presentation/frontend/widgets/typed/note_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachment_fixtures.dart';
import 'design_goldens_test.dart' show loadAppFonts;
import 'paper_canvas_test.dart' show host, phone, setWindow, studyNote;
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/core/local_store_settings.dart';

final typed = DocumentSchema('note-typed', 1);

NoteDocument simpleTyped() => NoteDocument.fromJson({
  'blocks': [
    {
      'id': 'h1',
      'kind': 'heading',
      'level': 1,
      'spans': [
        {'text': 'Photosynthesis'},
      ],
    },
    {
      'id': 'p1',
      'kind': 'paragraph',
      'spans': [
        {'text': 'Plants make sugar.'},
      ],
    },
  ],
}, schema: typed);

NoteDocument complexTyped() => NoteDocument.fromJson({
  'blocks': [
    ...(simpleTyped().toJson()['blocks'] as List),
    {
      'id': 't1',
      'kind': 'table',
      'header': true,
      'rows': [
        {
          'cells': [
            {
              'spans': [
                {'text': 'Plant'},
              ],
            },
          ],
        },
        {
          'cells': [
            {
              'spans': [
                {'text': 'Bean'},
              ],
            },
          ],
        },
      ],
    },
    {
      'id': 'c1',
      'kind': 'link_card',
      'url': 'https://example.org/a',
      'title': 'A source',
    },
  ],
}, schema: typed);

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the view of each note on each device', () {
    final paper = studyNote();
    expect(noteViewFor(PlatformProfile.fullWriter, paper), NoteView.paper);
    expect(noteViewFor(PlatformProfile.phone, paper), NoteView.readOnly);
    expect(noteViewFor(PlatformProfile.browser, paper), NoteView.readOnly);
    expect(noteViewFor(PlatformProfile.phone, simpleTyped()), NoteView.typed);
    expect(
      noteViewFor(PlatformProfile.phone, complexTyped()),
      NoteView.readOnly,
    );
    // Android tablets and iPads are full writers (annotations#16).
    expect(
      resolvePlatformProfile(
        isWeb: false,
        platform: TargetPlatform.android,
        shortestSideDp: 800,
      ),
      PlatformProfile.fullWriter,
    );
    expect(
      resolvePlatformProfile(
        isWeb: false,
        platform: TargetPlatform.iOS,
        isPad: true,
      ),
      PlatformProfile.fullWriter,
    );
  });

  late FileStore store;
  PaperHandler handlerFor(NoteDocument d, {String? title}) {
    store = FileStore();
    return PaperHandler(
      noteId: 'n1',
      document: d,
      title: title,
      autosave: NoteAutosave(
        store,
        settings: const LocalStoreSettings(
          autosaveDelay: Duration(milliseconds: 20),
        ),
      ),
    );
  }

  for (final (name, make) in [
    ('a paper note with ink, layout and cards', studyNote),
    ('a typed note with a table and a card', complexTyped),
  ]) {
    testWidgets('$name opens read-only on a phone and closes byte for byte '
        'unchanged', (tester) async {
      await setWindow(tester, phone);
      final document = make();
      final before = utf8.encode(jsonEncode(document.toJson()));
      final h = handlerFor(document, title: 'Study');
      addTearDown(h.dispose);
      await tester.pumpWidget(
        host(NoteScreen(handler: h, profile: PlatformProfile.phone)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paper-toolbar')), findsNothing);
      expect(find.byKey(const Key('typed-editor')), findsNothing);
      // Taps, a pen, keys and scrolling change nothing.
      for (final at in [const Offset(100, 200), const Offset(300, 500)]) {
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pen = await tester.startGesture(
        const Offset(120, 300),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(80, 20));
      await pen.up();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.drag(find.byType(MaterialApp), const Offset(0, -200));
      await tester.pumpAndSettle();
      await h.close();
      expect(store.saved, isEmpty);
      expect(utf8.encode(jsonEncode(h.document.toJson())), before);
    });
  }

  testWidgets('the typed editor: text, styles, Undo, the title; opening '
      'alone saves nothing', (tester) async {
    await setWindow(tester, phone);
    final h = handlerFor(simpleTyped(), title: 'Biology');
    addTearDown(h.dispose);
    await tester.pumpWidget(
      host(NoteScreen(handler: h, profile: PlatformProfile.phone)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('typed-editor')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(store.saved, isEmpty);
    // Type at the end of the paragraph.
    await tester.tap(find.byKey(const Key('typed-editor')));
    await tester.pump();
    final state = tester.state<State<StatefulWidget>>(
      find.byType(TypedNoteEditor),
    );
    final editor = (state as dynamic).typed;
    final c = editor.controller;
    c.updateSelection(
      TextSelection.collapsed(offset: c.document.length - 1),
      ChangeSource.local,
    );
    c.replaceText(c.document.length - 1, 0, '\nLight', null);
    await tester.pump(const Duration(milliseconds: 600));
    final blocks = (h.document as TypedDocument).blocks;
    expect(blocks, hasLength(3));
    expect(blocks.last.toJson()['spans'], [
      {'text': 'Light'},
    ]);
    // The new line as a bulleted list, then bold.
    c.updateSelection(
      TextSelection.collapsed(offset: c.document.length - 2),
      ChangeSource.local,
    );
    editor.setLineStyle(TypedLineStyle.bullets);
    await tester.pump(const Duration(milliseconds: 600));
    expect((h.document as TypedDocument).blocks.last.toJson()['kind'], 'list');
    // Undo brings the paragraph back; the editor follows.
    h.undo();
    await tester.pump();
    expect(
      (h.document as TypedDocument).blocks.last.toJson()['kind'],
      'paragraph',
    );
    // The title.
    await tester.enterText(find.byKey(const Key('typed-title')), 'Plants');
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.title, 'Plants');
    await h.close();
    expect(store.saved.last.title, 'Plants');
    expect(store.saved.last.document is TypedDocument, isTrue);
    await tester.pump(const Duration(seconds: 3));
  });

  final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
  for (final (mode, brightness) in const [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    testWidgets('review images, $mode', skip: review == null, (tester) async {
      Future<void> shot(String name) => expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$review/phone_${name}_$mode.png'),
      );
      await setWindow(tester, phone);
      for (final (name, make) in [
        ('typed_editor', simpleTyped),
        ('read_only_typed', complexTyped),
        ('read_only_paper', studyNote),
      ]) {
        final h = handlerFor(make(), title: 'Photosynthesis');
        await tester.pumpWidget(
          host(
            NoteScreen(
              key: ValueKey(name),
              handler: h,
              profile: PlatformProfile.phone,
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        await shot(name);
        if (name == 'typed_editor') {
          await tester.tap(find.byKey(const Key('typed-line-style')));
          await tester.pumpAndSettle();
          await shot('line_styles');
          await tester.tapAt(const Offset(200, 700));
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
        h.dispose();
        await tester.pump(const Duration(seconds: 1));
      }
    });
  }
}
