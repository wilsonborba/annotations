// annotations#62: an edit of a checked document checks only its changed
// items, with the same verdict as the full check.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_capacity_test.dart' show handwriting;

const rules = EditorRules(limits: NoteLimits());
final schema = DocumentSchema('note-original', 1);

String verdict(EditDecision d) => jsonEncode({
  'error': d.error == null
      ? null
      : [d.error!.rule, d.error!.code, d.error!.path, d.error!.items],
  'document': d.document.toJson(),
});

/// The decision on a checked [document] and the full check of a fresh copy
/// of it give the same verdict.
EditDecision same(NoteDocument document, Object? operation) {
  final fast = rules.check(document, operation);
  final fresh = NoteDocument.fromJson(
    document.toJson(),
    schema: document.schema,
  );
  expect(verdict(fast), verdict(rules.check(fresh, operation)));
  return fast;
}

Map<String, Object?> text(String id, num x, num y, {num width = 160}) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': width,
  'height': 40,
  'spans': [
    {'text': 'Block $id'},
  ],
};

void main() {
  test('every shared rule fixture keeps its verdict on a checked document', () {
    final files =
        Directory('test/fixtures/editor_rules')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, greaterThan(80));
    final hits = debugIncrementalChecks;
    var checked = 0;
    for (final f in files) {
      final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final document = NoteDocument.fromJson(
        c['document'],
        schema: DocumentSchema(
          c['family'] as String,
          c['schema_version'] as int,
        ),
      );
      final base = rules.check(document);
      if (!base.accepted || c['operation'] == null) continue;
      checked++;
      final fast = rules.check(base.document, c['operation']);
      final full = rules.check(document, c['operation']);
      expect(verdict(fast), verdict(full), reason: f.path);
      expect(
        fast.error == null ? 'valid' : 'invalid',
        c['expected'],
        reason: f.path,
      );
    }
    expect(checked, greaterThan(40));
    // ignore: avoid_print
    print(
      "fixtures: $checked edits, ${debugIncrementalChecks - hits} decided from the changed items",
    );
    // The changed-items check decided the accepted plain edits.
    expect(debugIncrementalChecks - hits, greaterThanOrEqualTo(7));
  });

  test('random edits of a note: the same verdicts as the full check', () {
    final rnd = Random(62);
    var doc = rules
        .check(
          NoteDocument.fromJson({
            'page': {
              'width': 1000,
              'background': {'kind': 'blank'},
            },
            'items': [
              for (var i = 0; i < 40; i++) handwriting(i),
              for (var i = 0; i < 12; i++)
                text('t$i', (i % 4) * 240, (i ~/ 4) * 80),
              text('g1a', 0, 400),
              text('g1b', 240, 400),
              {
                'id': 'g1',
                'kind': 'group',
                'members': ['g1a', 'g1b'],
              },
            ],
          }, schema: schema),
        )
        .document;
    var next = 0;
    num grid(int cells) => cells * 8;
    for (var round = 0; round < 300; round++) {
      final ids = [
        for (final it in (doc as PaperDocument).itemsJson) it['id'] as String,
      ];
      final id = ids[rnd.nextInt(ids.length)];
      final EditDecision d;
      switch (rnd.nextInt(7)) {
        case 0:
          d = same(doc, {
            'op': 'add',
            'item': text(
              'n${next++}',
              grid(rnd.nextInt(100)),
              grid(rnd.nextInt(80)),
            ),
          });
        case 1:
          d = same(doc, {'op': 'add', 'item': handwriting(1000 + next++)});
        case 2:
          d = same(doc, {
            'op': 'update',
            'id': id,
            'changes': {
              'x': grid(rnd.nextInt(110)),
              'y': grid(rnd.nextInt(80)),
            },
          });
        case 3:
          d = same(doc, {'op': 'delete', 'id': id});
        case 4:
          d = same(doc, {
            'op': 'batch',
            'steps': [
              {'op': 'delete', 'id': id},
              {
                'op': 'add',
                'item': text('n${next++}', grid(rnd.nextInt(100)), 4),
              },
            ],
          });
        case 5:
          final dx = rnd.nextInt(80) - 40;
          d = rules.move(doc, [id], dx, 16);
          final fresh = NoteDocument.fromJson(doc.toJson(), schema: schema);
          expect(verdict(d), verdict(rules.move(fresh, [id], dx, 16)));
        default:
          d = same(doc, {
            'op': 'replace',
            'item': text(id, grid(rnd.nextInt(100)), grid(rnd.nextInt(80))),
          });
      }
      if (d.accepted) doc = d.document;
    }
  });

  test('Undo and Redo of item edits give back each exact state', () {
    final start = rules
        .check(
          NoteDocument.fromJson({
            'page': {
              'width': 1000,
              'background': {'kind': 'blank'},
            },
            'items': [
              for (var i = 0; i < 10; i++) handwriting(i),
              for (var i = 0; i < 6; i++)
                text('t$i', (i % 3) * 240, (i ~/ 3) * 80),
            ],
          }, schema: schema),
        )
        .document;
    final editor = NotesEditor(start);
    final states = [jsonEncode(editor.document.toJson())];
    final command = HistoryCommand(CommandKind.ink);
    final edits = <Object>[
      {'op': 'add', 'item': handwriting(50)},
      {'op': 'delete', 'id': 's3'},
      {
        'op': 'update',
        'id': 't1',
        'changes': {'x': 480, 'y': 160},
      },
      {
        'op': 'batch',
        'steps': [
          {'op': 'delete', 'id': 't0'},
          {'op': 'add', 'item': text('t0', 0, 0)},
        ],
      },
      {'op': 'replace', 'item': handwriting(4)..['id'] = 's5'},
    ];
    for (final op in edits) {
      expect(editor.apply(command, (r, d) => r.check(d, op)).error, isNull);
      states.add(jsonEncode(editor.document.toJson()));
    }
    for (var i = states.length - 2; i >= 0; i--) {
      expect(editor.undo().moved, isTrue);
      expect(jsonEncode(editor.document.toJson()), states[i]);
    }
    for (var i = 1; i < states.length; i++) {
      expect(editor.redo().moved, isTrue);
      expect(jsonEncode(editor.document.toJson()), states[i]);
    }
  });

  test('30 dense pages: a stroke, a move and a text edit stay fast', () {
    const big = EditorRules(
      limits: NoteLimits(maxItems: 100000, maxDocumentBytes: 1 << 30),
    );
    final items = <Object?>[
      for (var i = 0; i < 30 * 800; i++) handwriting(i),
      for (var i = 0; i < 60; i++) text('t$i', (i % 4) * 240, 1104 + i * 56),
    ];
    final loaded = NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    }, schema: schema);
    final watch = Stopwatch()..start();
    final full = big.check(loaded);
    final fullMs = watch.elapsedMilliseconds;
    expect(full.error, isNull);
    // The median of several runs after a warm-up, in microseconds.
    int median(EditDecision Function(int run) edit) {
      edit(-1);
      final times = <int>[];
      for (var run = 0; run < 7; run++) {
        watch.reset();
        expect(edit(run).error, isNull);
        times.add(watch.elapsedMicroseconds);
      }
      return (times..sort())[times.length ~/ 2];
    }

    final doc = full.document;
    final stroke = median(
      (run) => big.check(doc, {'op': 'add', 'item': handwriting(900000 + run)}),
    );
    final move = median((run) => big.move(doc, ['t5'], 8, 0));
    final edit = median(
      (run) => big.editText(
        doc,
        't5',
        spans: [
          {'text': 'Edited $run'},
        ],
        measuredHeight: 40,
      ),
    );
    // A stroke through the editor: the check and its Undo step.
    final editor = NotesEditor(doc, rules: big);
    final commit = median(
      (run) => editor.apply(
        HistoryCommand(CommandKind.ink),
        (rules, d) =>
            rules.check(d, {'op': 'add', 'item': handwriting(800000 + run)}),
      ),
    );
    watch.reset();
    expect(editor.undo().moved, isTrue);
    final undo = watch.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      '30 pages (24000 strokes, 60 text blocks): full check $fullMs ms; '
      'stroke ${stroke / 1000} ms, move ${move / 1000} ms, '
      'text edit ${edit / 1000} ms, stroke with its Undo step '
      '${commit / 1000} ms, Undo $undo ms',
    );
    expect(commit, lessThan(100000));
    expect(undo, lessThan(300));
    // Run alone, a stroke takes a few ms, well within one 16 ms frame (the
    // numbers posted on annotations#62). The suite runs files in parallel,
    // so this bound only catches a fall back to the full check (over 1 s).
    expect(stroke, lessThan(100000));
  });
}
