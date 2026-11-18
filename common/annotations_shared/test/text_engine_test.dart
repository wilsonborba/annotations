// Gates of the text engine spike (annotations#23): lossless round trip, typed
// content without a widget, selected-span formatting, the type C guard on
// every mutation path, the one Notes history and IME composition.
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/dal/local/quill_text_engine.dart';
import 'package:annotations_shared/dal/local/text_engine.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:annotations_shared/domain/services/text_editing.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_goldens_test.dart' show loadAppFonts;

const engine = QuillTextEngine();

/// Every span list (text items, typed blocks, list items, table cells and
/// captions) in the valid document fixtures.
List<List<Object?>> fixtureSpans() {
  final found = <List<Object?>>[];
  void walk(Object? value) {
    if (value is Map) {
      for (final MapEntry(:key, :value) in value.entries) {
        if ((key == 'spans' || key == 'caption') && value is List) {
          found.add(value);
        } else {
          walk(value);
        }
      }
    } else if (value is List) {
      value.forEach(walk);
    }
  }

  for (final file in Directory(
    'test/fixtures/document_schema/valid',
  ).listSync()) {
    if (file.path.endsWith('.json')) {
      walk((jsonDecode((file as File).readAsStringSync()) as Map)['document']);
    }
  }
  return found;
}

NoteDocument paper(List<Object?> items, {String family = 'note-original'}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    }, schema: DocumentSchema(family, 1));

Map<String, Object?> textItem(String id, num y, List<Object?> spans) => {
  'id': id,
  'kind': 'text',
  'x': 40,
  'y': y,
  'width': 200,
  'height': 16,
  'spans': spans,
};

/// t1 at y 40 can grow to 56 units before it touches t2 at y 96. In tests
/// every line is 16 units high (the test font at size 16), so three lines fit
/// and four lines are rejected.
NotesEditor notes([List<Object?> spans = const []]) =>
    EditorSession.open(
          paper([
            textItem('t1', 40, spans),
            textItem('t2', 96, [
              {'text': 'Below'},
            ]),
          ]),
        )
        as NotesEditor;

Map<String, Object?> itemOf(EditorSession session, String id) =>
    ((session.document.toJson()['items'] as List).cast<Map<String, Object?>>())
        .firstWhere((item) => item['id'] == id);

String json(Object? value) => jsonEncode(value);

void main() {
  group('round trip', () {
    test('every fixture span list round trips exactly', () {
      final lists = fixtureSpans();
      expect(lists.length, greaterThan(10));
      for (final spans in lists) {
        expect(json(engine.load(spans).toSpans()), json(spans));
      }
    });

    test('all supported fields, explicit false, case and numbers', () {
      final spans = [
        {'text': 'Plain '},
        {'text': 'bold', 'bold': true},
        {
          'text': ' off',
          'bold': false,
          'italic': false,
          'strikethrough': false,
        },
        {'text': ' it', 'italic': true, 'strikethrough': true},
        {'text': ' lower', 'color': '#1e40afff'},
        {'text': ' upper', 'color': '#1E40AF80', 'size': 18},
        {'text': ' half', 'size': 12.5},
        {'text': ' ภาษาไทย ผู้ใหญ่ ', 'bold': true, 'color': '#000000FF'},
        {'text': 'ação é você\nline two\n'},
        {'text': '\tTab', 'italic': true},
      ];
      final content = engine.load(spans);
      expect(json(content.toSpans()), json(spans));
      expect(content.plainText, spans.map((s) => s['text']).join());
      // Saving the saved spans again gives the same result.
      expect(json(engine.load(content.toSpans()).toSpans()), json(spans));
    });

    test('canonical form joins equal neighbors and drops empty spans', () {
      final content = engine.load([
        {'text': 'a', 'bold': true},
        {'text': ''},
        {'text': 'b', 'bold': true},
      ]);
      expect(content.toSpans(), [
        {'text': 'ab', 'bold': true},
      ]);
    });

    test('unsupported stored fields are refused, not dropped', () {
      for (final (span, code) in [
        ({'text': 'a', 'underline': true}, 'unsupported_field'),
        ({'text': 'a', 'color': '#FFF'}, 'invalid_color'),
        ({'text': 'a', 'size': 0}, 'invalid_size'),
        ({'text': 'a', 'bold': 'yes'}, 'invalid_type'),
        ({'bold': true}, 'missing_field'),
      ]) {
        expect(
          () => engine.load([span]),
          throwsA(
            isA<TextContentException>().having((e) => e.code, 'code', code),
          ),
        );
      }
    });

    test('unsupported engine content is refused', () {
      for (final delta in [
        Delta()
          ..insert('a')
          ..insert('\n', {'header': 1}),
        Delta()
          ..insert('a', {'link': 'https://example.com'})
          ..insert('\n'),
        Delta()
          ..insert('a', {'underline': true})
          ..insert('\n'),
        Delta()
          ..insert({'image': 'x'})
          ..insert('\n'),
      ]) {
        expect(() => deltaToSpans(delta), throwsA(isA<TextContentException>()));
      }
    });
  });

  group('typed content without an editor widget', () {
    test('typed documents load, convert and change programmatically', () {
      for (final name in [
        'typed-paragraph',
        'typed-heading',
        'typed-list',
        'typed-table',
      ]) {
        final file = File('test/fixtures/document_schema/valid/$name.json');
        final fixture = jsonDecode(file.readAsStringSync()) as Map;
        final document = NoteDocument.fromJson(
          fixture['document'],
          schema: DocumentSchema('note-typed', 1),
        );
        expect(document, isA<TypedDocument>());
      }
      final content = engine.load([
        {'text': 'Photosynthesis '},
        {'text': 'needs light', 'bold': true},
      ]);
      final changed = content
          .replaced(15, 0, 'always ')
          .formatted(0, 14, const TextFormat.italic(true));
      expect(changed.toSpans(), [
        {'text': 'Photosynthesis', 'italic': true},
        {'text': ' always '},
        {'text': 'needs light', 'bold': true},
      ]);
      // The original content is not changed.
      expect(content.plainText, 'Photosynthesis needs light');
      expect(engine.measureHeight(changed.toSpans(), 200), greaterThan(0));
    });

    test('a typed URL does not become an unsupported link', () {
      final content = engine
          .load([
            {'text': 'see https://example.com'},
          ])
          .replaced(23, 0, ' ');
      expect(content.toSpans(), [
        {'text': 'see https://example.com '},
      ]);
    });
  });

  group('formatting of the selected span only', () {
    test('content formatting changes only the range', () {
      final content = engine.load([
        {'text': 'one two three'},
      ]);
      expect(content.formatted(4, 3, const TextFormat.bold(true)).toSpans(), [
        {'text': 'one '},
        {'text': 'two', 'bold': true},
        {'text': ' three'},
      ]);
      expect(
        content
            .formatted(0, 3, const TextFormat.color('#FF0000FF'))
            .formatted(8, 5, const TextFormat.size(20))
            .formatted(4, 3, const TextFormat.strikethrough(true))
            .toSpans(),
        [
          {'text': 'one', 'color': '#FF0000FF'},
          {'text': ' '},
          {'text': 'two', 'strikethrough': true},
          {'text': ' '},
          {'text': 'three', 'size': 20},
        ],
      );
    });

    test('controller formatting of a selection is one formatting step', () {
      final editor = notes([
        {'text': 'one two three', 'italic': true},
      ]);
      final controller = GuardedQuillController(
        engine: engine,
        binding: TextItemBinding(editor, 't1', engine),
      );
      controller.updateSelection(
        const TextSelection(baseOffset: 4, extentOffset: 7),
        ChangeSource.local,
      );
      controller.formatSelectionWith(const TextFormat.bold(true));
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'one ', 'italic': true},
        {'text': 'two', 'bold': true, 'italic': true},
        {'text': ' three', 'italic': true},
      ]);
      expect(editor.stepsBack, 1);
      controller.formatSelectionWith(const TextFormat.bold(false));
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'one two three', 'italic': true},
      ]);
      expect(editor.stepsBack, 2);
    });
  });

  group('type C guard on every mutation path', () {
    late NotesEditor editor;
    late TextItemBinding binding;
    late GuardedQuillController controller;
    late String start;
    final rejections = <TextCommit>[];

    setUp(() {
      editor = notes([
        {'text': 'a\nb'},
      ]);
      binding = TextItemBinding(editor, 't1', engine);
      rejections.clear();
      controller = GuardedQuillController(
        engine: engine,
        binding: binding,
        onRejected: rejections.add,
      );
      start = json(editor.document.toJson());
    });

    void expectUnchanged() {
      expect(json(editor.document.toJson()), start);
      expect(editor.stepsBack, 0);
      expect(
        json(controller.document.toDelta().toJson()),
        json(engine.load(binding.spans).delta.toJson()),
      );
    }

    test('accepted typing stores spans and the measured height', () {
      controller.replaceText(3, 0, 'c', null);
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'a\nbc'},
      ]);
      expect(itemOf(editor, 't1')['height'], 32);
      expect(editor.stepsBack, 1);
    });

    test('typing that would overlap a neighbor changes nothing', () {
      controller.replaceText(3, 0, '\nc\nd', null);
      expectUnchanged();
      expect(rejections.single.change.text, '\nc\nd');
      expect(binding.lastDecision!.accepted, isFalse);
      expect(controller.lastRejection, same(rejections.single));
    });

    test('a rejected paste keeps the pasted data', () async {
      controller.updateSelection(
        const TextSelection.collapsed(offset: 3),
        ChangeSource.local,
      );
      expect(controller.paste('\nfirst\nsecond'), isFalse);
      expectUnchanged();
      expect(rejections.single.change.kind, TextChangeKind.replacing);
      expect(rejections.single.change.text, '\nfirst\nsecond');
      // The rule decision keeps the requested spans for the UI.
      expect(jsonEncode(binding.lastDecision!.operation), contains('second'));
    });

    test('system clipboard paste and cut go through the guard', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      String? clipboard = 'X';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return {'text': clipboard};
            }
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      controller.updateSelection(
        const TextSelection.collapsed(offset: 1),
        ChangeSource.local,
      );
      await controller.clipboardPaste();
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'aX\nb'},
      ]);
      controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 2),
        ChangeSource.local,
      );
      expect(controller.clipboardSelection(false), isTrue);
      expect(clipboard, 'aX');
      expect(itemOf(editor, 't1')['spans'], [
        {'text': '\nb'},
      ]);
      expect(editor.stepsBack, 2);
      clipboard = 'p\nq\nr';
      await controller.clipboardPaste();
      expect(itemOf(editor, 't1')['spans'], [
        {'text': '\nb'},
      ]);
      expect(rejections.single.change.text, 'p\nq\nr');
    });

    test('formatting that grows the text is rejected', () {
      controller.formatText(0, 3, const SizeAttribute('40'));
      expectUnchanged();
      controller.formatText(0, 1, Attribute.fromKeyValue('size', 60));
      expectUnchanged();
      expect(rejections, hasLength(2));
      expect(rejections.last.change.kind, TextChangeKind.formatting);
    });

    test('unsupported formats are rejected, not stored', () {
      controller.formatText(0, 1, Attribute.h1);
      controller.formatText(0, 1, Attribute.ul);
      controller.formatText(0, 1, Attribute.underline);
      controller.indentSelection(true);
      expectUnchanged();
      expect(rejections, hasLength(4));
      expect(rejections.first.error, isA<TextContentException>());
    });

    test('deleting, programmatic replacement and document setting', () {
      controller.replaceText(1, 2, '', null);
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'a'},
      ]);
      expect(itemOf(editor, 't1')['height'], 16);
      controller.document = Document.fromDelta(Delta()..insert('1\n2\n3\n4\n'));
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'a'},
      ]);
      controller.compose(
        Delta()..insert('new '),
        const TextSelection.collapsed(offset: 4),
        ChangeSource.remote,
      );
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'new a'},
      ]);
      // The four-line document was rejected: two steps.
      expect(editor.stepsBack, 2);
    });
  });

  group('one Notes history', () {
    test('the Quill history is off and Undo uses the Notes history', () {
      final editor = notes();
      final binding = TextItemBinding(editor, 't1', engine);
      final controller = GuardedQuillController(
        engine: engine,
        binding: binding,
      );
      for (final (i, c) in 'ab cd'.split('').indexed) {
        controller.replaceText(i, 0, c, null);
      }
      expect(controller.document.history.ignoreChange, isTrue);
      expect(controller.document.history.hasUndo, isFalse);
      // Typing in one word joins; a new word after a space starts a step.
      expect(editor.stepsBack, 2);
      expect(controller.hasUndo, isTrue);
      controller.undo();
      expect(itemOf(editor, 't1')['spans'], [
        {'text': 'ab '},
      ]);
      expect(controller.document.toPlainText(), 'ab \n');
      controller.redo();
      expect(controller.document.toPlainText(), 'ab cd\n');
    });

    test('Instant has no Undo: the keys do nothing', () {
      final room = EditorSession.open(
        paper([
          textItem('t1', 40, [
            {'text': 'a'},
          ]),
        ], family: 'instant-room'),
      );
      expect(room, isA<InstantEditor>());
      final controller = GuardedQuillController(
        engine: engine,
        binding: TextItemBinding(room, 't1', engine),
      );
      controller.replaceText(1, 0, 'b', null);
      expect(itemOf(room, 't1')['spans'], [
        {'text': 'ab'},
      ]);
      expect(controller.hasUndo, isFalse);
      controller.undo();
      expect(itemOf(room, 't1')['spans'], [
        {'text': 'ab'},
      ]);
    });
  });

  group('system keyboard and IME in a mounted editor', () {
    late NotesEditor editor;
    late GuardedQuillController controller;
    final key = GlobalKey<QuillEditorState>();

    Future<void> mount(WidgetTester tester, List<Object?> spans) async {
      editor = notes(spans);
      controller = GuardedQuillController(
        engine: engine,
        binding: TextItemBinding(editor, 't1', engine),
      )..composingRange = quillComposingRange(key);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates:
              FlutterQuillLocalizations.localizationsDelegates,
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              child: QuillEditor(
                key: key,
                controller: controller,
                focusNode: FocusNode(),
                scrollController: ScrollController(),
                config: QuillEditorConfig(
                  customStyles: engine.styles,
                  scrollable: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    Future<void> input(
      WidgetTester tester,
      String text, {
      TextRange composing = TextRange.empty,
    }) async {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '$text\n',
          selection: TextSelection.collapsed(offset: text.length),
          composing: composing,
        ),
      );
      await tester.pump();
    }

    List<Object?> spans() => itemOf(editor, 't1')['spans'] as List<Object?>;

    testWidgets('English typing from the system keyboard', (tester) async {
      await mount(tester, []);
      await input(tester, 'H');
      await input(tester, 'Hi');
      expect(spans(), [
        {'text': 'Hi'},
      ]);
      expect(editor.stepsBack, 1);
    });

    testWidgets('Thai composition commits once', (tester) async {
      await mount(tester, []);
      // A Thai keyboard composing a consonant with a vowel and a tone mark.
      await input(tester, 'ก', composing: const TextRange(start: 0, end: 1));
      await input(tester, 'กี', composing: const TextRange(start: 0, end: 2));
      await input(tester, 'กี่', composing: const TextRange(start: 0, end: 3));
      expect(spans(), isEmpty, reason: 'composing updates are not commits');
      expect(editor.stepsBack, 0);
      await input(tester, 'กี่ ');
      expect(spans(), [
        {'text': 'กี่ '},
      ]);
      expect(editor.stepsBack, 1);
      // Thai without composition (direct characters) also commits.
      await input(tester, 'กี่ ผู้');
      expect(spans(), [
        {'text': 'กี่ ผู้'},
      ]);
    });

    testWidgets('pt-BR dead key accent becomes one composition step', (
      tester,
    ) async {
      await mount(tester, [
        {'text': 'voc'},
      ]);
      // The dead key shows its accent as composing text, then the vowel
      // replaces it with the composed letter.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'voc^\n',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 3, end: 4),
        ),
      );
      await tester.pump();
      expect(spans(), [
        {'text': 'voc'},
      ]);
      await input(tester, 'você');
      expect(spans(), [
        {'text': 'você'},
      ]);
      expect(editor.stepsBack, 1);
      await input(tester, 'você ação');
      expect(spans(), [
        {'text': 'você ação'},
      ]);
    });

    testWidgets('a rejected IME commit changes nothing and keeps the text', (
      tester,
    ) async {
      await mount(tester, [
        {'text': 'a\nb'},
      ]);
      final rejected = <TextCommit>[];
      controller.onRejected = rejected.add;
      // Composing text that would need a fourth line is shown, never cut.
      await input(
        tester,
        'a\nb\nc\nก',
        composing: const TextRange(start: 6, end: 7),
      );
      expect(controller.document.toPlainText(), 'a\nb\nc\nก\n');
      expect(spans(), [
        {'text': 'a\nb'},
      ]);
      await input(tester, 'a\nb\nc\nกา');
      expect(spans(), [
        {'text': 'a\nb'},
      ]);
      expect(editor.stepsBack, 0);
      expect(rejected.single.change.kind, TextChangeKind.composition);
      expect(rejected.single.change.text, '\nc\nกา');
      expect(controller.document.toPlainText(), 'a\nb\n');
    });

    testWidgets('Undo and Redo keys use the one history', (tester) async {
      await mount(tester, []);
      await input(tester, 'one');
      controller.formatText(0, 3, Attribute.bold);
      expect(editor.stepsBack, 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(spans(), [
        {'text': 'one'},
      ]);
      expect(editor.stepsBack, 1);
      expect(editor.stepsForward, 1);
    });

    testWidgets('the measured height is the rendered editor height', (
      tester,
    ) async {
      final cases = [
        [
          {'text': 'one line'},
        ],
        [
          {'text': 'a much longer text that wraps over several lines here'},
        ],
        [
          {'text': 'big', 'size': 30},
          {'text': '\nsmall\n', 'size': 10},
        ],
      ];
      for (final spans in cases) {
        await mount(tester, spans);
        final rendered = tester.getSize(find.byKey(key)).height;
        expect(engine.measureHeight(spans, 200), closeTo(rendered, 0.01));
      }
    });
  });

  group('font family in an app (annotations#59)', () {
    test('the text style names the package fonts like the theme', () {
      expect(annotationsTextStyle.fontFamily, appFontFamily);
      expect(annotationsTextStyle.fontFamilyFallback, appFontFallback);
      final paragraph = engine.styles.paragraph!.style;
      expect(paragraph.fontFamily, appFontFamily);
      expect(paragraph.fontFamilyFallback, appFontFallback);
    });

    test('measuring uses Ubuntu Sans and the Thai fallback', () async {
      // Only the names that an app registers are loaded (see loadAppFonts).
      await loadAppFonts();
      double width(String text, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final result = painter.width;
        painter.dispose();
        return result;
      }

      for (final text in ['Annotations', 'สวัสดีครับ']) {
        final app = width(
          text,
          const TextStyle(
            fontFamily: appFontFamily,
            fontFamilyFallback: appFontFallback,
            fontSize: 16,
          ),
        );
        final unknown = width(
          text,
          const TextStyle(fontFamily: 'Unknown', fontSize: 16),
        );
        expect(app, isNot(closeTo(unknown, 0.5)), reason: text);
        expect(width(text, annotationsTextStyle), closeTo(app, 0.01));
      }
    });
  });
}
