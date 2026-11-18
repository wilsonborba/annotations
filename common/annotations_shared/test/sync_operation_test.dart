// annotations#19 part C: a sync sends the change as one operation; applied
// to the base revision it gives exactly the current document.
import 'dart:convert';

import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:annotations_shared/domain/services/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'note_capacity_test.dart' show handwriting;

final schema = DocumentSchema('note-original', 1);
const rules = EditorRules(limits: NoteLimits());

NoteDocument doc(List<Object?> items, {bool dots = false}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': dots
            ? {'kind': 'dots', 'spacing': 24, 'visibility': 0.5}
            : {'kind': 'blank'},
      },
      'items': items,
    }, schema: schema);

Map<String, Object?> text(String id, int y) => {
  'id': id,
  'kind': 'text',
  'x': 0,
  'y': y,
  'width': 200,
  'height': 40,
  'spans': [
    {'text': 'Block $id'},
  ],
};

void expectSync(NoteDocument base, NoteDocument current) {
  final op = syncOperation(base, current);
  final result = op == null ? base : rules.check(base, op).document;
  expect(rules.check(base, op).error, isNull, reason: jsonEncode(op));
  expect(jsonEncode(result.toJson()), jsonEncode(current.toJson()));
}

void main() {
  final base = [text('t1', 0), handwriting(1), text('t2', 200), handwriting(2)];

  test('no change gives no operation', () {
    expect(syncOperation(doc(base), doc(base)), isNull);
  });

  test('an added stroke is one add, not the whole note', () {
    final big = [for (var i = 0; i < 2000; i++) handwriting(i)];
    final current = [...big, handwriting(5000)];
    final op = syncOperation(doc(big), doc(current))!;
    expect((op['steps'] as List).single, containsPair('op', 'add'));
    expect(
      jsonEncode(op).length,
      lessThan(jsonEncode(doc(current).toJson()).length ~/ 100),
    );
    expectSync(doc(big), doc(current));
  });

  test('changes, removals, page settings and order are exact', () {
    final changed = [...base];
    changed[0] = {...text('t1', 0), 'width': 160};
    expectSync(doc(base), doc(changed));
    expectSync(doc(base), doc([base[0], base[2], base[3]]));
    expectSync(doc(base), doc(base, dots: true));
    // A new item in the middle (a partial erase): the later items follow
    // it again, so the drawing order is the same.
    expectSync(
      doc(base),
      doc([base[0], handwriting(9), handwriting(10), base[2], base[3]]),
    );
    // A moved item.
    expectSync(doc(base), doc([base[1], base[0], base[2], base[3]]));
  });

  test('typed documents send their whole document', () {
    final typed = NoteDocument.fromJson({
      'blocks': [],
    }, schema: DocumentSchema('note-typed', 1));
    expect(syncOperation(typed, typed), isNull);
  });
}
