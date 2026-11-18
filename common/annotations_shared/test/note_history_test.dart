import 'dart:convert';

import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:flutter_test/flutter_test.dart';

NoteDocument paper(List<Object?> items, {String family = 'note-original'}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    }, schema: DocumentSchema(family, 1));

Map<String, Object?> text(String id, num x, num y, [String body = '']) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': 200,
  'height': 100,
  'spans': [
    {'text': body},
  ],
};

Map<String, Object?> stroke(String id, num x0, num y0, num x1, num y1) {
  int h(num v) => (v * 100).round();
  return {
    'id': id,
    'kind': 'stroke',
    'tool': 'round',
    'brush_version': 1,
    'width': 2.5,
    'color': '#000000FF',
    'opacity': 1,
    'samples': {
      'x': [h(x0), h(x1)],
      'y': [h(y0), h(y1)],
      't': [0, 8],
    },
    'nodes': [
      {'x': h(x0), 'y': h(y0), 'mode': 'smooth', 'corner': false, 'sample': 0},
      {'x': h(x1), 'y': h(y1), 'mode': 'smooth', 'corner': false, 'sample': 1},
    ],
  };
}

String json(NoteDocument d) => jsonEncode(d.toJson());
Map<String, Object?> itemOf(NoteDocument d, String id) => [
  for (final it in d.toJson()['items'] as List) it as Map<String, Object?>,
].firstWhere((it) => it['id'] == id);
List<String> idsOf(NoteDocument d) => [
  for (final it in d.toJson()['items'] as List) (it as Map)['id'] as String,
];
String textOf(NoteDocument d, String id) =>
    ((itemOf(d, id)['spans'] as List).single as Map)['text'] as String;

final move = HistoryCommand(CommandKind.move);

EditDecision moveBy(NotesEditor e, String id, num dx, [num dy = 0]) =>
    e.apply(move, (rules, d) => rules.move(d, [id], dx, dy));

EditDecision deleteItem(EditorRules rules, NoteDocument d, String id) =>
    rules.check(d, {'op': 'delete', 'id': id});

/// A fake clock that tests move forward by hand.
final class Clock {
  DateTime now = DateTime.utc(2026, 11, 17);
  DateTime call() => now;
  void wait(int ms) => now = now.add(Duration(milliseconds: ms));
}

void main() {
  group('limits', () {
    test('the default limit is the confirmed 100 steps', () {
      expect(const HistorySettings().maxSteps, 100);
    });

    test('101 commands keep the last 100', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      for (var i = 0; i < 101; i++) {
        expect(moveBy(editor, 'a', 0, 8).accepted, isTrue);
      }
      expect(editor.stepsBack, 100);
      expect(itemOf(editor.document, 'a')['y'], 808);
      for (var i = 0; i < 100; i++) {
        expect(editor.undo().moved, isTrue);
      }
      // The first command was dropped: Undo stops at its result.
      expect(itemOf(editor.document, 'a')['y'], 8);
      expect(editor.canUndo, isFalse);
      expect(editor.undo().moved, isFalse);
      expect(editor.stepsForward, 100);
    });

    test('the limit is a setting', () {
      final editor = NotesEditor(
        paper([text('a', 0, 0)]),
        settings: const HistorySettings(maxSteps: 3),
      );
      for (var i = 0; i < 5; i++) {
        moveBy(editor, 'a', 8);
      }
      expect(editor.stepsBack, 3);
    });

    test('a new command clears redo', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      moveBy(editor, 'a', 8);
      moveBy(editor, 'a', 8);
      editor.undo();
      expect(editor.stepsForward, 1);
      moveBy(editor, 'a', 0, 8);
      expect(editor.stepsForward, 0);
      expect(editor.canRedo, isFalse);
      expect(editor.stepsBack, 2);
    });

    test('steps back and forward are reported for the notice', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      for (var i = 0; i < 3; i++) {
        moveBy(editor, 'a', 8);
      }
      final back = editor.undo();
      expect((back.moved, back.stepsBack, back.stepsForward), (true, 2, 1));
      final forward = editor.redo();
      expect(
        (forward.moved, forward.stepsBack, forward.stepsForward),
        (true, 3, 0),
      );
    });
  });

  group('committed edits only', () {
    test('a rejected candidate never creates a step', () {
      final editor = NotesEditor(paper([text('a', 0, 0), text('b', 304, 0)]));
      final before = json(editor.document);
      final decision = moveBy(editor, 'a', 250);
      expect(decision.accepted, isFalse);
      expect(editor.stepsBack, 0);
      expect(json(editor.document), before);
    });

    test('an accepted edit without a change creates no step', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      moveBy(editor, 'a', 0);
      expect(editor.stepsBack, 0);
    });

    test('previews during a drag do not create steps', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      for (var dx = 1; dx < 50; dx++) {
        editor.rules.move(editor.document, ['a'], dx, 0);
      }
      expect(editor.stepsBack, 0);
      moveBy(editor, 'a', 50);
      expect(editor.stepsBack, 1);
    });
  });

  group('exact states', () {
    test('Undo and Redo restore exact states and never move other items', () {
      final editor = NotesEditor(
        paper([
          text('a', 0, 0),
          stroke('s', 10, 300, 90, 320),
          text('b', 0, 496),
        ]),
      );
      final states = [json(editor.document)];
      moveBy(editor, 'a', 300);
      states.add(json(editor.document));
      editor.apply(
        HistoryCommand(CommandKind.resize),
        (rules, d) => rules.resize(d, 'b', width: 300, measuredHeight: 80),
      );
      states.add(json(editor.document));
      editor.apply(
        HistoryCommand(CommandKind.remove),
        (rules, d) => deleteItem(rules, d, 's'),
      );
      states.add(json(editor.document));
      editor.apply(
        HistoryCommand(CommandKind.paste),
        (rules, d) => rules.paste(
          d,
          [text('c', 0, 0, 'copy')],
          dx: 600,
          newId: () => 'c2',
        ),
      );
      states.add(json(editor.document));

      for (var i = states.length - 2; i >= 0; i--) {
        expect(editor.undo().moved, isTrue);
        expect(json(editor.document), states[i]);
      }
      // The removed stroke came back at its own place in the order.
      expect(idsOf(editor.document), ['a', 's', 'b']);
      for (var i = 1; i < states.length; i++) {
        expect(editor.redo().moved, isTrue);
        expect(json(editor.document), states[i]);
      }
    });

    test('group and ungroup are steps', () {
      final editor = NotesEditor(paper([text('a', 0, 0), text('b', 0, 304)]));
      final start = json(editor.document);
      editor.apply(
        HistoryCommand(CommandKind.group),
        (rules, d) => rules.check(d, {
          'op': 'add',
          'item': {
            'id': 'g',
            'kind': 'group',
            'members': ['a', 'b'],
          },
        }),
      );
      final grouped = json(editor.document);
      editor.apply(
        HistoryCommand(CommandKind.ungroup),
        (rules, d) => deleteItem(rules, d, 'g'),
      );
      expect(json(editor.document), start);
      editor.undo();
      expect(json(editor.document), grouped);
      editor.undo();
      expect(json(editor.document), start);
    });

    test('a page change is a step', () {
      final editor = NotesEditor(paper([text('a', 0, 0)]));
      final start = json(editor.document);
      editor.apply(
        HistoryCommand(CommandKind.page),
        (rules, d) => rules.check(d, {
          'op': 'page',
          'page': {
            'width': 1000,
            'background': {'kind': 'dots', 'spacing': 24, 'visibility': 0.5},
          },
        }),
      );
      expect(editor.stepsBack, 1);
      editor.undo();
      expect(json(editor.document), start);
    });
  });

  group('one completed gesture is one step', () {
    test('one drag of a point is one step', () {
      final editor = NotesEditor(paper([stroke('s', 10, 10, 90, 20)]));
      final start = json(editor.document);
      Map<String, Object?> dragTo(int x) {
        final nodes = [
          for (final n in itemOf(editor.document, 's')['nodes'] as List)
            {...(n as Map).cast<String, Object?>()},
        ];
        nodes[1]['x'] = x;
        return {
          'op': 'update',
          'id': 's',
          'changes': {'nodes': nodes},
        };
      }

      // The drag only previews candidates.
      for (var x = 9000; x < 12000; x += 500) {
        expect(editor.rules.check(editor.document, dragTo(x)).accepted, isTrue);
      }
      expect(editor.stepsBack, 0);
      // The release commits once.
      editor.apply(
        HistoryCommand(CommandKind.points),
        (rules, d) => rules.check(d, dragTo(12000)),
      );
      expect(editor.stepsBack, 1);
      expect(
        (itemOf(editor.document, 's')['nodes'] as List)[1],
        containsPair('x', 12000),
      );
      editor.undo();
      expect(json(editor.document), start);
    });

    test('one stroke is one step', () {
      final editor = NotesEditor(paper([]));
      editor.apply(
        HistoryCommand(CommandKind.ink),
        (rules, d) =>
            rules.check(d, {'op': 'add', 'item': stroke('s', 0, 0, 50, 50)}),
      );
      expect(editor.stepsBack, 1);
      editor.undo();
      expect(idsOf(editor.document), isEmpty);
    });

    test('one live erase gesture is one step', () {
      final editor = NotesEditor(
        paper([
          stroke('s1', 0, 0, 50, 0),
          text('t', 0, 96),
          stroke('s2', 0, 300, 50, 300),
        ]),
      );
      final start = json(editor.document);
      final gesture = editor.begin(HistoryCommand(CommandKind.erase));
      gesture.apply((rules, d) => deleteItem(rules, d, 's1'));
      // Erasing is live: the document changes at once, without a step yet.
      expect(idsOf(editor.document), ['t', 's2']);
      expect(editor.stepsBack, 0);
      expect(editor.canUndo, isFalse);
      expect(() => editor.undo(), throwsStateError);
      expect(() => moveBy(editor, 't', 1), throwsStateError);
      gesture.apply((rules, d) => deleteItem(rules, d, 's2'));
      expect(gesture.end(), isTrue);
      expect(editor.stepsBack, 1);
      expect(idsOf(editor.document), ['t']);
      editor.undo();
      expect(json(editor.document), start);
      editor.redo();
      expect(idsOf(editor.document), ['t']);
    });

    test('a cancelled gesture restores its start without a step', () {
      final editor = NotesEditor(paper([stroke('s1', 0, 0, 50, 0)]));
      final start = json(editor.document);
      final gesture = editor.begin(HistoryCommand(CommandKind.erase));
      gesture.apply((rules, d) => deleteItem(rules, d, 's1'));
      gesture.cancel();
      expect(json(editor.document), start);
      expect(editor.stepsBack, 0);
      expect(() => gesture.end(), throwsStateError);
    });

    test('a gesture without a change creates no step', () {
      final editor = NotesEditor(paper([text('t', 0, 0)]));
      expect(editor.begin(HistoryCommand(CommandKind.erase)).end(), isFalse);
      expect(editor.stepsBack, 0);
    });
  });

  group('text coalescing', () {
    late Clock clock;
    late NotesEditor editor;
    late String body;

    EditDecision commit(TextInput input, String next, {num height = 100}) {
      final decision = editor.apply(
        HistoryCommand.text('t', input),
        (rules, d) => rules.editText(
          d,
          't',
          spans: [
            {'text': next},
          ],
          measuredHeight: height,
        ),
      );
      if (decision.accepted) body = next;
      return decision;
    }

    void type(String s, {int pause = 100}) {
      clock.wait(pause);
      commit(TextInput.typing(body.length, s), body + s);
    }

    void backspace({int pause = 100}) {
      clock.wait(pause);
      commit(
        TextInput.deleting(body.length - 1, 1),
        body.substring(0, body.length - 1),
      );
    }

    setUp(() {
      clock = Clock();
      body = '';
      editor = NotesEditor(
        paper([text('t', 0, 0), text('u', 0, 304)]),
        clock: clock.call,
      );
    });

    test('a word and its following space are one step', () {
      for (final c in 'hello '.split('')) {
        type(c);
      }
      expect(editor.stepsBack, 1);
      for (final c in 'world'.split('')) {
        type(c);
      }
      expect(editor.stepsBack, 2);
      editor.undo();
      expect(textOf(editor.document, 't'), 'hello ');
      editor.undo();
      expect(textOf(editor.document, 't'), '');
    });

    test('a pause longer than the window starts a new step', () {
      type('a');
      type('b', pause: 1000);
      expect(editor.stepsBack, 1);
      type('c', pause: 1001);
      expect(editor.stepsBack, 2);
    });

    test('typing elsewhere in the text starts a new step', () {
      type('abc');
      clock.wait(100);
      commit(TextInput.typing(0, 'x'), 'xabc');
      expect(editor.stepsBack, 2);
    });

    test('Backspace runs join, and switching between typing and deleting '
        'starts a new step', () {
      type('abcd');
      backspace();
      backspace();
      expect(editor.stepsBack, 2);
      type('z');
      expect(editor.stepsBack, 3);
      editor.undo();
      expect(textOf(editor.document, 't'), 'ab');
      editor.undo();
      expect(textOf(editor.document, 't'), 'abcd');
    });

    test('forward Delete runs join', () {
      type('abcd');
      clock.wait(100);
      commit(TextInput.deleting(0, 1), 'bcd');
      clock.wait(100);
      commit(TextInput.deleting(0, 1), 'cd');
      expect(editor.stepsBack, 2);
    });

    test('paste, formatting and other items never join', () {
      type('ab');
      clock.wait(10);
      commit(TextInput.replacing(2, 0), 'abPASTE');
      clock.wait(10);
      commit(TextInput.replacing(7, 0), 'abPASTE2');
      expect(editor.stepsBack, 3);
      editor.apply(
        HistoryCommand(CommandKind.formatting),
        (rules, d) => rules.editText(
          d,
          't',
          spans: [
            {'text': body, 'bold': true},
          ],
          measuredHeight: 100,
        ),
      );
      expect(editor.stepsBack, 4);
      editor.apply(
        HistoryCommand.text('u', TextInput.typing(0, 'q')),
        (rules, d) => rules.editText(
          d,
          'u',
          spans: [
            {'text': 'q'},
          ],
          measuredHeight: 100,
        ),
      );
      expect(editor.stepsBack, 5);
    });

    test('Undo, Redo and other commands end the text step', () {
      type('a');
      type('b');
      editor.undo();
      body = '';
      type('a');
      expect(editor.stepsBack, 1);
      moveBy(editor, 'u', 8);
      type('b');
      expect(editor.stepsBack, 3);
    });

    test('rejected text input creates no step', () {
      type('a');
      clock.wait(10);
      final decision = commit(TextInput.typing(1, 'b'), 'ab', height: 400);
      expect(decision.accepted, isFalse);
      expect(editor.stepsBack, 1);
      expect(textOf(editor.document, 't'), 'a');
    });

    test('an IME composition is one step only after commit', () {
      type('ok ');
      final start = json(editor.document);
      final ime = editor.begin(
        HistoryCommand.text('t', TextInput.composition(3, 2)),
      );
      // Composing updates the engine keeps in the document.
      for (final composing in ['ok ส', 'ok สว', 'ok สวั', 'ok สวัส']) {
        ime.apply(
          (rules, d) => rules.editText(
            d,
            't',
            spans: [
              {'text': composing},
            ],
            measuredHeight: 100,
          ),
        );
        expect(editor.stepsBack, 1);
      }
      expect(ime.end(), isTrue);
      expect(editor.stepsBack, 2);
      body = 'ok สวัส';
      // The next typing never joins the committed composition.
      type('ดี');
      expect(editor.stepsBack, 3);
      editor.undo();
      editor.undo();
      expect(json(editor.document), start);
    });

    test('IME commits sent without composing updates are one step each', () {
      clock.wait(10);
      commit(TextInput.composition(0, 2), 'สว');
      clock.wait(10);
      commit(TextInput.composition(2, 2), 'สวัส');
      expect(editor.stepsBack, 2);
    });
  });

  group('memory only', () {
    test('the history is empty when the note is opened again', () {
      final original = paper([text('a', 0, 0)]);
      final editor = EditorSession.open(original) as NotesEditor;
      moveBy(editor, 'a', 8);
      moveBy(editor, 'a', 8);
      editor.undo();
      expect((editor.stepsBack, editor.stepsForward), (1, 1));
      // Close: only the document is saved. It holds no history field.
      final saved = editor.document.toJson();
      expect(saved.keys.toSet(), original.toJson().keys.toSet());
      expect(
        jsonEncode(saved),
        json(editor.rules.move(original, ['a'], 8, 0).document),
      );
      final reopened =
          EditorSession.open(
                NoteDocument.fromJson(saved, schema: original.schema),
              )
              as NotesEditor;
      expect((reopened.stepsBack, reopened.stepsForward), (0, 0));
      expect(reopened.canUndo, isFalse);
      expect(reopened.canRedo, isFalse);
    });

    test('a typed note is a Notes document with history', () {
      final typed = NoteDocument.fromJson({
        'blocks': <Object?>[],
      }, schema: DocumentSchema('note-typed', 1));
      final session = EditorSession.open(typed);
      expect(session, isA<NotesEditor>());
      expect(session.mode, EditorMode.notes);
    });
  });

  group('Instant', () {
    final room = paper([text('a', 0, 0)], family: 'instant-room');

    test('Instant offers no Undo and no Redo', () {
      final session = EditorSession.open(room);
      expect(session.mode, EditorMode.instant);
      expect(session, isA<InstantEditor>());
      expect(session, isNot(isA<UndoRedo>()));
      expect(session, isNot(isA<NotesEditor>()));
      final dynamic untyped = session;
      expect(() => untyped.undo(), throwsNoSuchMethodError);
      expect(() => untyped.redo(), throwsNoSuchMethodError);
      expect(() => untyped.stepsBack, throwsNoSuchMethodError);
    });

    test('an Instant room cannot get a Notes history', () {
      expect(() => NotesEditor(room), throwsArgumentError);
    });

    test('an accepted Instant edit is kept and cannot be taken back', () {
      final session = EditorSession.open(room) as InstantEditor;
      final decision = session.apply(
        (rules, d) => rules.check(d, {'op': 'delete', 'id': 'a'}),
      );
      expect(decision.accepted, isTrue);
      expect(idsOf(session.document), isEmpty);
    });
  });
}
