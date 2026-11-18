// Typed text blocks on the paper canvas (annotations#27): a click starts a
// block in free space, the text tools act on the selection, and the type C
// space limit shows the red border, the brief shake and the message without
// losing input or moving anything.
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/local/quill_text_engine.dart';
import 'package:annotations_shared/dal/local/text_engine.dart';
import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/services/text_blocks.dart';
import 'package:annotations_shared/domain/services/text_editing.dart';
import 'package:annotations_shared/presentation/frontend/components/controls.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/components/tokens.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/text_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';
import 'paper_canvas_test.dart' show handlerFor, schema, setWindow, text;

/// A page with a neighbor block below the place where a new block starts
/// (40, 100): one line fits, a second line would overlap it.
NoteDocument neighborNote() => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.5},
  },
  'items': [
    text('below', 40, 130, 420, 24, [
      {'text': 'The neighbor block stays where it is.'},
    ]),
    text('right', 700, 40, 260, 120, [
      {'text': 'A block on the right'},
    ]),
  ],
}, schema: schema);

/// The review page: a note with room for five lines above a section title.
NoteDocument reviewNote() => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'ruled', 'spacing': 32, 'visibility': 0.5},
  },
  'items': [
    text('below', 40, 130, 420, 24, [
      {'text': 'The neighbor block stays where it is.'},
    ]),
    text('next', 520, 400, 440, 24, [
      {'text': 'Next section: the Calvin cycle', 'bold': true},
    ]),
  ],
}, schema: schema);

const engine = QuillTextEngine();

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('text blocks (domain)', () {
    const blocks = TextBlocks();
    const rules = EditorRules();
    num line(num width) => engine.measureHeight(const [], width);

    TextBlockPlace? place(NoteDocument d, num x, num y) => blocks.place(
      rules,
      d,
      id: 'new',
      x: x,
      y: y,
      width: 320,
      minWidth: 40,
      lineHeight: line,
    );

    test('a new block takes the free width and stores nothing', () {
      final d = neighborNote();
      final before = jsonEncode(d.toJson());
      final free = place(d, 40, 100)!;
      expect([free.x, free.y, free.width], [40, 100, 320]);
      // A block on the right ends the width where it starts.
      expect(place(d, 500, 60)!.width, 200);
      // The page edge ends the width.
      expect(place(d, 900, 400)!.width, 100);
      // No block narrower than the minimum, and none on another block.
      expect(place(d, 680, 60), isNull);
      expect(place(d, 40, 120), isNull, reason: 'one line overlaps below');
      expect(jsonEncode(d.toJson()), before);
    });

    test('empty paper and text hits in Type mode', () {
      final layout = DocumentLayout.of(neighborNote())!;
      expect(blocks.textAt(layout, InkVec(50, 140)), 'below');
      expect(blocks.isEmptyPaper(layout, InkVec(50, 140)), false);
      expect(blocks.isEmptyPaper(layout, InkVec(50, 300)), true);
    });

    test('the first input adds the block as one step', () {
      final editor = NotesEditor(neighborNote());
      final binding = TextItemBinding(
        editor,
        'new',
        engine,
        place: const TextBlockPlace(40, 100, 320),
      );
      expect(binding.spans, isEmpty);
      final spans = [
        {'text': 'Hello'},
      ];
      final result = binding.commit(
        TextChange(
          kind: TextChangeKind.typing,
          offset: 0,
          length: 5,
          text: 'Hello',
          spans: spans,
        ),
      );
      expect(result.accepted, isTrue);
      expect(binding.spans, spans);
      expect(editor.stepsBack, 1);
      final item = binding.stored!.bounds!;
      expect([item.x, item.y, item.width], [40, 100, 320]);
      expect(item.height, line(320));
      editor.undo();
      expect(binding.stored, isNull, reason: 'Undo removes the new block');
    });
  });

  group('text blocks on the paper', () {
    late PaperHandler paper;
    late TextHandler texts;
    late Preferences preferences;
    var ids = 0;

    Future<void> pump(
      WidgetTester tester, {
      NoteDocument? document,
      Brightness brightness = Brightness.light,
      bool reducedMotion = false,
      Size size = const Size(1280, 900),
    }) async {
      await setWindow(tester, size);
      ids = 0;
      paper = handlerFor(document ?? neighborNote());
      preferences = Preferences();
      texts = TextHandler(
        paper: paper,
        preferences: preferences,
        newId: () => 'new${ids++}',
      );
      addTearDown(texts.dispose);
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
              data: MediaQueryData(
                size: size,
                disableAnimations: reducedMotion,
              ),
              child: Material(
                child: PaperScreen(handler: paper, text: texts),
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

    Future<void> clickAt(WidgetTester tester, double x, double y) async {
      await tester.tapAt(screenOf(x, y));
      await tester.pump();
      await tester.pump();
    }

    Future<void> input(
      WidgetTester tester,
      String value, {
      TextRange composing = TextRange.empty,
      int? selection,
    }) async {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '$value\n',
          selection: TextSelection.collapsed(offset: selection ?? value.length),
          composing: composing,
        ),
      );
      await tester.pump();
    }

    Map<String, Object?>? item(String id) {
      final items = paper.document.toJson()['items'] as List;
      for (final it in items) {
        if ((it as Map)['id'] == id) return it.cast<String, Object?>();
      }
      return null;
    }

    Finder byKey(String key) => find.byKey(Key(key));

    /// Closes the block and lets autosave and the cursor timers finish.
    Future<void> finish(WidgetTester tester) async {
      texts.end();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    /// Starts a block at (40, 100) under which the neighbor leaves one line.
    Future<void> startBlocked(WidgetTester tester, [String first = 'a']) async {
      await clickAt(tester, 60, 100);
      expect(texts.editing, 'new0');
      await input(tester, first);
      expect(item('new0')!['spans'], [
        {'text': first},
      ]);
    }

    testWidgets('a click on empty paper starts a block with the tools', (
      tester,
    ) async {
      await pump(tester);
      expect(byKey('text-tools'), findsNothing);
      await clickAt(tester, 60, 400);
      expect(texts.editing, 'new0');
      expect(byKey('text-tools'), findsOneWidget);
      expect(item('new0'), isNull, reason: 'an empty block is not stored');
      await input(tester, 'Light reactions');
      final stored = item('new0')!;
      expect(stored['spans'], [
        {'text': 'Light reactions'},
      ]);
      expect([stored['x'], stored['y'], stored['width']], [60, 400, 320]);
      // A click elsewhere closes the block; a click on it opens it again.
      await clickAt(tester, 600, 700);
      expect(texts.editing, 'new1');
      await clickAt(tester, 600, 900);
      expect(item('new1'), isNull, reason: 'a block left empty is dropped');
      await clickAt(tester, 70, 405);
      expect(texts.editing, 'new0');
      expect(texts.controller!.selection.baseOffset, greaterThan(0));
      await finish(tester);
    });

    testWidgets('formatting applies only to the selection', (tester) async {
      await pump(tester);
      await clickAt(tester, 60, 400);
      await input(tester, 'hello world');
      texts.controller!.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5),
        ChangeSource.local,
      );
      await tester.pump();
      await tester.tap(byKey('text-tool-bold'));
      await tester.pump();
      await tester.tap(byKey('text-tool-color'));
      await tester.pumpAndSettle();
      await tester.tap(byKey('text-color-colorBlue'));
      await tester.pumpAndSettle();
      expect(item('new0')!['spans'], [
        {'text': 'hello', 'bold': true, 'color': '#3D5AFEFF'},
        {'text': ' world'},
      ]);
      // The selection stays after the tools, and the tools show its state.
      expect(texts.controller!.selection.extentOffset, 5);
      expect(texts.format['bold'], isTrue);
      final bold = tester.widget<AppIconButton>(byKey('text-tool-bold'));
      expect(bold.selected, isTrue);
      expect(
        tester.widget<AppIconButton>(byKey('text-tool-italic')).selected,
        isFalse,
      );
      // A size on another selection changes only that selection.
      texts.controller!.updateSelection(
        const TextSelection(baseOffset: 6, extentOffset: 11),
        ChangeSource.local,
      );
      texts.size(12);
      await tester.pump();
      expect(item('new0')!['spans'], [
        {'text': 'hello', 'bold': true, 'color': '#3D5AFEFF'},
        {'text': ' '},
        {'text': 'world', 'size': 12},
      ]);
      await finish(tester);
    });

    testWidgets('typing into a blocked block never deletes text', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester);
      final before = jsonEncode(paper.document.toJson());
      final height = paper.pageHeight;
      await input(tester, 'a\nb');
      expect(jsonEncode(paper.document.toJson()), before);
      expect(texts.controller!.lastRejection!.change.text, '\nb');
      expect(texts.limited, isTrue);
      expect(byKey('text-limit-border'), findsOneWidget);
      expect(byKey('text-limit-message'), findsOneWidget);
      // Deleting never needs space and is accepted.
      await input(tester, '');
      expect(item('new0')!['spans'], isEmpty);
      expect(texts.limited, isFalse);
      expect(paper.pageHeight, height);
      await finish(tester);
    });

    testWidgets('Thai composition in a blocked block keeps every character', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester, 'ก');
      final before = jsonEncode(paper.document.toJson());
      // The composing text needs a second line. It is shown and the IME
      // composing region stays as the keyboard sent it; nothing is cut.
      await input(
        tester,
        'ก\nสว',
        composing: const TextRange(start: 2, end: 4),
      );
      final key = texts.editorKey;
      expect(quillComposingRange(key)(), const TextRange(start: 2, end: 4));
      expect(texts.controller!.document.toPlainText(), 'ก\nสว\n');
      expect(jsonEncode(paper.document.toJson()), before);
      expect(texts.limited, isFalse, reason: 'composing is not a commit');
      await input(
        tester,
        'ก\nสวั',
        composing: const TextRange(start: 2, end: 5),
      );
      expect(texts.controller!.document.toPlainText(), 'ก\nสวั\n');
      // The commit does not fit: the stored text stays, the composed text
      // is kept in the rejection, and the limit feedback shows.
      await input(tester, 'ก\nสวัส');
      expect(jsonEncode(paper.document.toJson()), before);
      expect(item('new0')!['spans'], [
        {'text': 'ก'},
      ]);
      expect(texts.controller!.lastRejection!.change.text, '\nสวัส');
      expect(texts.limited, isTrue);
      expect(byKey('text-limit-message'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a rejected paste inserts nothing and keeps the clipboard', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester);
      var clipboard = 'first\nsecond\nthird';
      var writes = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.setData') {
            writes++;
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final before = jsonEncode(paper.document.toJson());
      await texts.controller!.clipboardPaste();
      await tester.pump();
      expect(jsonEncode(paper.document.toJson()), before);
      expect(texts.controller!.document.toPlainText(), 'a\n');
      expect(clipboard, 'first\nsecond\nthird');
      expect(writes, 0);
      expect(texts.limited, isTrue);
      expect(byKey('text-limit-message'), findsOneWidget);
      await finish(tester);
    });

    Rect blockOnScreen(String id) {
      final b = item(id)!;
      return Rect.fromPoints(
        screenOf((b['x'] as num).toDouble(), (b['y'] as num).toDouble()),
        screenOf(
          (b['x'] as num) + (b['width'] as num) * 1.0,
          (b['y'] as num) + (b['height'] as num) * 1.0,
        ),
      );
    }

    testWidgets('a one-line block keeps a readable message as an overlay', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester);
      final items = jsonEncode(paper.document.toJson()['items']);
      final height = paper.pageHeight;
      final screenRect = tester.getRect(find.byType(PaperScreen));
      await input(tester, 'a\nb');
      await tester.pumpAndSettle();
      expect(byKey('text-limit-message'), findsOneWidget);
      // Nothing moves and the page does not grow (manager decision
      // beba260dbd7145ae8d1086ea833dc585).
      expect(jsonEncode(paper.document.toJson()['items']), items);
      expect(paper.pageHeight, height);
      expect(tester.getRect(find.byType(PaperScreen)), screenRect);
      // The text has the normal small UI size and is not scaled down: its
      // rectangle on screen is its laid out size.
      final context = tester.element(byKey('text-limit-text'));
      final small = Theme.of(context).textTheme.bodySmall!.fontSize!;
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: byKey('text-limit-text'),
          matching: find.byType(RichText),
        ),
      );
      expect(paragraph.text.style!.fontSize, greaterThanOrEqualTo(small));
      final shown = tester.getRect(byKey('text-limit-text'));
      expect(shown.height, closeTo(paragraph.size.height, 0.01));
      expect(shown.width, closeTo(paragraph.size.width, 0.01));
      // The overlay starts at the block, is at least as wide as the block
      // and extends below the short block.
      final block = blockOnScreen('new0');
      final message = tester.getRect(byKey('text-limit-message'));
      expect(message.topLeft, offsetMoreOrLessEquals(block.topLeft));
      expect(message.width, greaterThanOrEqualTo(block.width));
      expect(message.bottom, greaterThan(block.bottom));
      // The buttons outside the block area still work.
      await tester.tap(byKey('text-limit-ok'));
      await tester.pump();
      expect(byKey('text-limit-message'), findsNothing);
      expect(jsonEncode(paper.document.toJson()['items']), items);
      await finish(tester);
    });

    testWidgets('a tall block keeps the message inside its area', (
      tester,
    ) async {
      await pump(
        tester,
        document: NoteDocument.fromJson({
          'page': {
            'width': 1000,
            'background': {'kind': 'blank'},
          },
          'items': [
            text('next', 40, 400, 440, 24, [
              {'text': 'Next section'},
            ]),
          ],
        }, schema: schema),
      );
      await clickAt(tester, 40, 100);
      var value = 'line 0';
      await input(tester, value);
      for (var i = 1; i < 40 && !texts.limited; i++) {
        value = '$value\nline $i';
        await input(tester, value);
      }
      expect(texts.limited, isTrue);
      await tester.pumpAndSettle();
      final block = blockOnScreen('new0');
      final message = tester.getRect(byKey('text-limit-message'));
      expect(message, rectMoreOrLessEquals(block));
      await finish(tester);
    });

    testWidgets('OK shows the text again; the next block shows it again', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester);
      await input(tester, 'a\nb');
      await tester.pumpAndSettle();
      await tester.tap(byKey('text-limit-ok'));
      await tester.pump();
      expect(byKey('text-limit-message'), findsNothing);
      expect(texts.controller!.document.toPlainText(), 'a\n');
      await input(tester, 'a\nc');
      await tester.pumpAndSettle();
      expect(byKey('text-limit-message'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("Don't show again keeps the red border and the shake", (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester);
      await input(tester, 'a\nb');
      await tester.pumpAndSettle();
      await tester.tap(byKey('text-limit-never'));
      await tester.pumpAndSettle();
      expect(byKey('text-limit-message'), findsNothing);
      expect(preferences.spaceLimitMessage, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'annotations.spaceLimitMessage',
        ),
        'off',
      );
      await input(tester, 'a\nc');
      await tester.pump(const Duration(milliseconds: 40));
      expect(byKey('text-limit-message'), findsNothing);
      expect(byKey('text-limit-border'), findsOneWidget);
      expect(shakeOffset(tester), isNot(0));
      await tester.pumpAndSettle();
      expect(shakeOffset(tester), 0);
      await finish(tester);
    });

    testWidgets('reduced motion removes the shake, the red border stays', (
      tester,
    ) async {
      await pump(tester, reducedMotion: true);
      await startBlocked(tester);
      await input(tester, 'a\nb');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        expect(shakeOffset(tester), 0);
      }
      expect(tester.hasRunningAnimations, isFalse);
      final border = tester.widget<DecoratedBox>(byKey('text-limit-border'));
      final colors = AppColors.light;
      expect(
        (border.decoration as BoxDecoration).border!.top.color,
        colors.danger,
      );
      await finish(tester);
    });

    testWidgets('a growing size that does not fit is a blocked input', (
      tester,
    ) async {
      await pump(tester);
      await startBlocked(tester, 'big');
      texts.controller!.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 3),
        ChangeSource.local,
      );
      texts.size(32);
      await tester.pump();
      expect(item('new0')!['spans'], [
        {'text': 'big'},
      ]);
      expect(texts.limited, isTrue);
      await finish(tester);
    });

    // Review images for the manager (H7). Not golden checks: they are
    // written only when ANNOTATIONS_REVIEW_DIR is set.
    final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
    for (final brightness in Brightness.values) {
      final mode = brightness.name;
      Future<void> shot(WidgetTester tester, String name) async {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('$review/text_${name}_$mode.png'),
        );
      }

      testWidgets('review images, $mode', skip: review == null, (tester) async {
        // Desktop look: real panel shadows, no touch selection handles.
        debugDisableShadows = false;
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        await pump(
          tester,
          document: reviewNote(),
          brightness: brightness,
          size: const Size(1000, 640),
        );
        await clickAt(tester, 60, 220);
        await input(tester, 'Photosynthesis turns light into sugar.');
        texts.controller!.updateSelection(
          const TextSelection(baseOffset: 0, extentOffset: 14),
          ChangeSource.local,
        );
        texts.toggle('bold');
        await tester.pump();
        await shot(tester, 'editing');
        await tester.tap(byKey('text-tool-color'));
        await tester.pumpAndSettle();
        await shot(tester, 'tools_color');
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        // A block with room for a few lines above the neighbor.
        const lines =
            'Light reactions happen in the thylakoids.\n'
            'They make ATP and NADPH.\n'
            'The Calvin cycle uses them\nin the stroma.\nOxygen is released.';
        await clickAt(tester, 520, 300);
        await input(tester, lines);
        await input(tester, '$lines\nx');
        await tester.pumpAndSettle();
        await shot(tester, 'limit_message');
        // The same state in a one-line block: the message scales down to
        // stay inside the block area.
        await clickAt(tester, 60, 100);
        await input(tester, 'Light reactions');
        await input(tester, 'Light reactions\nx');
        await tester.pumpAndSettle();
        await shot(tester, 'limit_message_one_line');
        await tester.tap(byKey('text-limit-never'));
        await tester.pumpAndSettle();
        await input(tester, 'Light reactions\ny');
        await tester.pumpAndSettle();
        await shot(tester, 'limit_no_message');
        preferences.spaceLimitMessage = true;
        await finish(tester);
        debugDisableShadows = true;
        debugDefaultTargetPlatformOverride = null;
      });
    }
  });
}

/// The sideways offset of the shake.
double shakeOffset(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byKey(const Key('text-limit-shake')),
          matching: find.byType(Transform),
        )
        .first,
  );
  return transform.transform.getTranslation().x;
}
