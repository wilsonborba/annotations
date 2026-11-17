import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/core/note_limits.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/editor_rules.dart';
import 'package:flutter_test/flutter_test.dart';

// Unchanged copies of wilsonborba/annotations_api at
// 5317abb5e5ec5f68bdf42d84e18a8c8d7440ade6, tests/fixtures/editor_rules.
// scripts/check_rule_fixtures.sh compares them with that commit.
final fixtureDirectory = Directory('test/fixtures/editor_rules');
const rules = EditorRules();

NoteDocument paper(List<Object?> items, {num width = 1000}) =>
    NoteDocument.fromJson({
      'page': {
        'width': width,
        'background': {'kind': 'blank'},
      },
      'items': items,
    }, schema: DocumentSchema('note-original', 1));

Map<String, Object?> text(
  String id,
  num x,
  num y, {
  num width = 200,
  num height = 100,
  List<Object?>? spans,
}) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': width,
  'height': height,
  'spans':
      spans ??
      [
        {'text': 'Block $id'},
      ],
};

Map<String, Object?> box(String id, String kind, num x, num y, num w, num h) =>
    switch (kind) {
      'image' => {'file_id': 'f_$id'},
      'link_card' => {'url': 'https://example.org/', 'title': 'Example'},
      'csv_table' => {'file_id': 'f_$id'},
      _ => <String, Object?>{},
    }..addAll({
      'id': id,
      'kind': kind,
      'x': x,
      'y': y,
      'width': w,
      'height': h,
    });

/// A two-point stroke between page-unit points.
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

Map<String, Object?> groupItem(String id, List<String> members) => {
  'id': id,
  'kind': 'group',
  'members': members,
};

List<Map<String, Object?>> itemsOf(NoteDocument d) => [
  for (final it in d.toJson()['items'] as List) it as Map<String, Object?>,
];
Map<String, Object?> itemOf(NoteDocument d, String id) =>
    itemsOf(d).firstWhere((it) => it['id'] == id);

/// Items that [changed] does not list keep their JSON and their order.
void expectNeighborsKept(
  NoteDocument before,
  NoteDocument after,
  Set<String> changed,
) {
  List<String> kept(NoteDocument d) => [
    for (final it in itemsOf(d))
      if (!changed.contains(it['id'])) jsonEncode(it),
  ];
  expect(kept(after), kept(before));
}

Matcher rejected(String rule, String code, List<String> items) =>
    isA<EditDecision>()
        .having((d) => d.accepted, 'accepted', false)
        .having((d) => d.error!.rule, 'rule', rule)
        .having((d) => d.error!.code, 'code', code)
        .having((d) => d.error!.items, 'items', items);

/// Ids that a fixture operation names.
void named(Object? op, Set<String> out) {
  if (op is! Map) return;
  for (final s in (op['steps'] as List? ?? const [])) {
    named(s, out);
  }
  if (op['id'] case final String id) out.add(id);
  if (op['item'] case {'id': final String id}) out.add(id);
}

void main() {
  group('shared rule fixtures', () {
    final files =
        fixtureDirectory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    test('the copy holds every backend case', () {
      expect(files, hasLength(75));
      final rulesSeen = <String>{};
      for (final f in files) {
        final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        rulesSeen.add(c['rule_id'] as String);
      }
      expect(rulesSeen, {
        'block_overlap',
        'group_overlap',
        'free_ink_overlap',
        'page_bounds',
        'operation',
        'document_schema',
      });
    });

    for (final file in files) {
      final name = file.uri.pathSegments.last;
      test(name, () {
        final c = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final document = NoteDocument.fromJson(
          c['document'],
          schema: DocumentSchema(
            c['family'] as String,
            c['schema_version'] as int,
          ),
        );
        final decision = rules.check(document, c['operation']);
        if (c['expected'] == 'valid') {
          expect(decision.error, isNull, reason: '${decision.error}');
          final ids = <String>{};
          named(c['operation'], ids);
          if (c['operation'] != null) {
            expectNeighborsKept(document, decision.document, ids);
          }
        } else {
          final error = c['error'] as Map<String, dynamic>;
          expect(
            decision,
            rejected(
              c['rule_id'] as String,
              error['code'] as String,
              (error['items'] as List).cast<String>(),
            ),
          );
          // A rejection keeps the stored document unchanged.
          expect(
            jsonEncode(decision.document.toJson()),
            jsonEncode(c['document']),
          );
        }
      });
    }
  });

  test('every valid document schema fixture passes the app schema check', () {
    final valid = Directory(
      'test/fixtures/document_schema/valid',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    expect(valid, hasLength(43));
    for (final f in valid) {
      final c = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final document = NoteDocument.fromJson(
        c['document'],
        schema: DocumentSchema(
          c['family'] as String,
          c['schema_version'] as int,
        ),
      );
      // These cases test the schema only; some of them overlap on purpose.
      final error = rules.check(document).error;
      expect(
        error?.rule,
        anyOf(isNull, 'block_overlap', 'group_overlap'),
        reason: '${f.path}: $error',
      );
    }
  });

  group('check', () {
    test('a rejection carries no content, only rule, code, path and ids', () {
      final doc = paper([text('t1', 0, 0), text('t2', 0, 100)]);
      final d = rules.check(doc, {
        'op': 'update',
        'id': 't1',
        'changes': {
          'height': 101,
          'spans': [
            {'text': 'private words'},
          ],
        },
      });
      expect(d, rejected('block_overlap', 'block_overlap', ['t1', 't2']));
      expect(d.error.toString(), isNot(contains('private')));
      expect(d.error!.path, 'items[1]');
      // The rejected input is kept for the UI.
      expect(jsonEncode(d.operation), contains('private words'));
      expect(itemOf(d.document, 't1')['height'], 100);
      expect(
        (d.candidate!['items'] as List).first,
        containsPair('height', 101),
      );
    });

    test('a non JSON operation is an invalid operation', () {
      final d = rules.check(paper([]), {'op': 'add', 'item': double.nan});
      expect(d, rejected('operation', 'invalid_operation', []));
    });

    test('the returned operation and candidate are independent copies', () {
      final op = {'op': 'add', 'item': text('t1', 0, 0)};
      final d = rules.check(paper([]), op);
      (op['item'] as Map)['x'] = 500;
      (d.operation as Map)['op'] = 'delete';
      expect((d.operation as Map)['op'], 'add');
      expect(itemOf(d.document, 't1')['x'], 0);
    });

    test('document limits match the backend', () {
      const limits = NoteLimits();
      expect(limits.maxItems, 10000);
      expect(limits.maxSamplesPerStroke, 10000);
      expect(limits.maxNodesPerStroke, 1000);
      expect(limits.maxDocumentBytes, 7500000);
      final small = EditorRules(limits: const NoteLimits(maxItems: 1));
      expect(
        small.check(paper([text('t1', 0, 0), text('t2', 300, 0)])),
        rejected('document_schema', 'too_many_items', []),
      );
    });
  });

  group('move', () {
    test('a valid drop moves only the named item', () {
      final doc = paper([
        text('t1', 0, 0),
        text('t2', 300, 0),
        stroke('s1', 10, 10, 90, 90),
      ]);
      final d = rules.move(doc, ['t1'], 20.004, 300);
      expect(d.accepted, isTrue);
      expect(itemOf(d.document, 't1'), containsPair('x', 20));
      expect(itemOf(d.document, 't1'), containsPair('y', 300));
      // Free ink does not follow the block.
      expectNeighborsKept(doc, d.document, {'t1'});
    });

    test('an invalid drop is red: the candidate shows it, nothing changes', () {
      final doc = paper([text('t1', 0, 0), text('t2', 300, 0)]);
      final d = rules.move(doc, ['t1'], 150, 50);
      expect(d, rejected('block_overlap', 'block_overlap', ['t1', 't2']));
      expect(itemOf(d.document, 't1')['x'], 0);
      expect((d.candidate!['items'] as List).first, containsPair('x', 150));
    });

    test('touching edges are allowed', () {
      final doc = paper([text('t1', 0, 0), text('t2', 300, 0)]);
      expect(rules.move(doc, ['t1'], 100, 0).accepted, isTrue);
    });

    test('a group moves with every member, ink included', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
        text('t2', 0, 400),
      ]);
      final d = rules.move(doc, ['g1'], 10, 20);
      expect(d.accepted, isTrue);
      expect(itemOf(d.document, 't1'), containsPair('x', 10));
      final samples = itemOf(d.document, 's1')['samples'] as Map;
      expect(samples['x'], [3000, 19000]);
      expect(samples['y'], [14000, 17000]);
      final nodes = itemOf(d.document, 's1')['nodes'] as List;
      expect(nodes.first, containsPair('x', 3000));
      expectNeighborsKept(doc, d.document, {'t1', 's1'});
      // Its ink makes the group rectangle larger.
      expect(
        rules.move(doc, ['g1'], 0, 260),
        rejected('group_overlap', 'group_overlap', ['g1', 't2']),
      );
    });

    test('free ink and shapes move over blocks', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 300, 300, 400, 400),
        {
          'id': 'h1',
          'kind': 'shape',
          'shape': 'circle',
          'color': '#FF0000FF',
          'line_width': 2,
          'opacity': 1,
          'center': {'x': 500, 'y': 500},
          'radius': 20,
        },
      ]);
      final d = rules.move(doc, ['s1', 'h1'], -250, -250);
      expect(d.accepted, isTrue);
      expect(itemOf(d.document, 'h1')['center'], {'x': 250, 'y': 250});
    });

    test('a move past the page width is out of bounds', () {
      final doc = paper([text('t1', 700, 0)]);
      expect(
        rules.move(doc, ['t1'], 101, 0),
        rejected('page_bounds', 'out_of_bounds', ['t1']),
      );
    });

    test('an unknown id names the missing item', () {
      expect(
        rules.move(paper([]), ['t9'], 1, 1),
        rejected('operation', 'missing_item', ['t9']),
      );
    });
  });

  group('type C text input', () {
    final doc = paper([text('t1', 0, 0), text('t2', 0, 200)]);
    final spans = [
      {'text': 'A longer text that wraps'},
    ];

    test('text grows into free space with the measured height', () {
      final d = rules.editText(doc, 't1', spans: spans, measuredHeight: 200);
      expect(d.accepted, isTrue);
      expect(itemOf(d.document, 't1')['height'], 200);
      expect(itemOf(d.document, 't1')['spans'], spans);
      expectNeighborsKept(doc, d.document, {'t1'});
    });

    test('growth into a neighbor is rejected with the blocking ids', () {
      final d = rules.editText(doc, 't1', spans: spans, measuredHeight: 201);
      expect(d, rejected('block_overlap', 'block_overlap', ['t1', 't2']));
      expect(d.error.toString(), isNot(contains('wraps')));
      // The composing text is not lost.
      final op = d.operation as Map;
      expect((op['changes'] as Map)['spans'], spans);
      expect(itemOf(d.document, 't1')['height'], 100);
    });

    test('a missing measurement never commits and keeps the text', () {
      final d = rules.editText(doc, 't1', spans: spans, measuredHeight: null);
      expect(d, rejected('editor', 'measurement_required', ['t1']));
      expect(((d.operation as Map)['changes'] as Map)['spans'], spans);
      expect(d.candidate, isNull);
    });
  });

  group('resize (B3)', () {
    test(
      'text keeps its font size; the width wraps to the measured height',
      () {
        final doc = paper([
          text(
            't1',
            0,
            0,
            spans: [
              {'text': 'Words', 'size': 16},
            ],
          ),
          text('t2', 0, 200),
        ]);
        final d = rules.resize(doc, 't1', width: 120, measuredHeight: 180);
        expect(d.accepted, isTrue);
        final t1 = itemOf(d.document, 't1');
        expect([t1['width'], t1['height']], [120, 180]);
        expect((t1['spans'] as List).first, containsPair('size', 16));
        expect(
          rules.resize(doc, 't1', width: 120, measuredHeight: 201),
          rejected('block_overlap', 'block_overlap', ['t1', 't2']),
        );
        expect(
          rules.resize(doc, 't1', width: 120),
          rejected('editor', 'measurement_required', ['t1']),
        );
        // From a left corner the right edge stays; text still grows downward.
        final left = rules.resize(
          doc,
          't1',
          width: 150,
          anchor: ResizeAnchor.bottomRight,
          measuredHeight: 150,
        );
        final t = itemOf(left.document, 't1');
        expect([t['x'], t['y'], t['width'], t['height']], [50, 0, 150, 150]);
      },
    );

    test('an image keeps its proportions from any corner', () {
      final doc = paper([box('i1', 'image', 100, 100, 200, 100)]);
      final d = rules.resize(
        doc,
        'i1',
        width: 300,
        height: 999,
        anchor: ResizeAnchor.bottomRight,
      );
      expect(d.accepted, isTrue);
      final i1 = itemOf(d.document, 'i1');
      expect([i1['x'], i1['y'], i1['width'], i1['height']], [0, 50, 300, 150]);
    });

    test('a CSV table resizes its area freely; a card needs a measurement', () {
      final doc = paper([
        box('c1', 'csv_table', 0, 0, 200, 100),
        box('l1', 'link_card', 300, 0, 200, 100),
      ]);
      final c1 = itemOf(
        rules.resize(doc, 'c1', width: 250, height: 60).document,
        'c1',
      );
      expect([c1['width'], c1['height']], [250, 60]);
      expect(
        rules.resize(doc, 'l1', width: 120),
        rejected('editor', 'measurement_required', ['l1']),
      );
      final l1 = itemOf(
        rules.resize(doc, 'l1', width: 120, measuredHeight: 140).document,
        'l1',
      );
      expect([l1['width'], l1['height']], [120, 140]);
    });

    test('a drawing scales its points and its line width', () {
      final doc = paper([stroke('s1', 100, 100, 200, 150)]);
      final d = rules.resize(doc, 's1', width: 200);
      expect(d.accepted, isTrue);
      final s1 = itemOf(d.document, 's1');
      expect(s1['width'], 5);
      expect((s1['samples'] as Map)['x'], [10000, 30000]);
      expect((s1['samples'] as Map)['y'], [10000, 20000]);
      expect((s1['samples'] as Map)['t'], [0, 8]);
    });

    test('a resize below the minimum size is rejected', () {
      final doc = paper([box('i1', 'image', 0, 0, 200, 100)]);
      expect(
        rules.resize(doc, 'i1', width: 10),
        rejected('editor', 'below_minimum_size', ['i1']),
      );
      expect(const EditorSettings().minResizeExtent, 8);
    });

    test('a group corner scales all members, text size and ink width', () {
      final doc = paper([
        text(
          't1',
          0,
          0,
          spans: [
            {'text': 'Sized', 'size': 20},
            {'text': 'Default'},
          ],
        ),
        stroke('s1', 0, 120, 200, 150),
        groupItem('g1', ['t1', 's1']),
      ]);
      final asked = <(String, int)>[];
      final d = rules.resize(
        doc,
        'g1',
        width: 300,
        effectiveFontSize: (id, n) {
          asked.add((id, n));
          return 16;
        },
      );
      expect(d.accepted, isTrue, reason: '${d.error}');
      // The resolver is asked only for the span without a stored size.
      expect(asked, [('t1', 1)]);
      final t1 = itemOf(d.document, 't1');
      expect([t1['width'], t1['height']], [300, 150]);
      expect((t1['spans'] as List).map((s) => (s as Map)['size']), [30, 24]);
      final s1 = itemOf(d.document, 's1');
      expect(s1['width'], 3.75);
      expect((s1['samples'] as Map)['x'], [0, 30000]);
      expect((s1['samples'] as Map)['y'], [18000, 22500]);
    });

    test('a group scale without a needed measurement never commits', () {
      final doc = paper([
        text('t1', 0, 0),
        box('l1', 'link_card', 0, 120, 200, 80),
        groupItem('g1', ['t1', 'l1']),
      ]);
      expect(
        rules.resize(doc, 'g1', width: 300, effectiveFontSize: (_, _) => 16),
        rejected('editor', 'measurement_required', ['l1']),
      );
      expect(
        rules.resize(doc, 'g1', width: 300, measuredHeights: {'l1': 90}),
        rejected('editor', 'measurement_required', ['t1']),
      );
      final d = rules.resize(
        doc,
        'g1',
        width: 300,
        measuredHeights: {'l1': 90},
        effectiveFontSize: (_, _) => 16,
      );
      expect(d.accepted, isTrue, reason: '${d.error}');
      final l1 = itemOf(d.document, 'l1');
      expect([l1['x'], l1['y'], l1['width'], l1['height']], [0, 180, 300, 90]);
    });

    test('a member resize uses its own rule and grows the group rectangle', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
        text('t2', 300, 0),
      ]);
      final ok = rules.resize(doc, 't1', width: 300, measuredHeight: 60);
      expect(ok.accepted, isTrue);
      // The member text wraps; the ink is not stretched.
      expectNeighborsKept(doc, ok.document, {'t1'});
      expect(
        rules.resize(doc, 't1', width: 301, measuredHeight: 60),
        rejected('group_overlap', 'group_overlap', ['g1', 't2']),
      );
    });
  });

  group('paste and duplicate', () {
    var n = 0;
    String newId() => 'p${++n}';
    setUp(() => n = 0);

    test('a paste that cannot fit adds nothing and keeps its data', () {
      final doc = paper([text('t1', 0, 0)]);
      final d = rules.paste(doc, [text('c1', 0, 0)], dx: 50, newId: newId);
      expect(d, rejected('block_overlap', 'block_overlap', ['t1', 'p1']));
      expect(itemsOf(d.document), hasLength(1));
      final op = d.operation as Map;
      expect(jsonEncode(op), contains('Block c1'));
    });

    test('a paste in free space adds copies with new ids', () {
      final doc = paper([text('t1', 0, 0)]);
      final d = rules.paste(doc, [text('c1', 0, 0)], dy: 100, newId: newId);
      expect(d.accepted, isTrue);
      expect(itemOf(d.document, 'p1'), containsPair('y', 100));
      expectNeighborsKept(doc, d.document, {'p1'});
    });

    test('duplicate keeps group layout and identity with new ids', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
      ]);
      final d = rules.duplicate(doc, ['g1'], dx: 300, newId: newId);
      expect(d.accepted, isTrue, reason: '${d.error}');
      final items = itemsOf(d.document);
      expect(items, hasLength(6));
      expect(itemOf(d.document, 'p3')['members'], ['p1', 'p2']);
      expect(itemOf(d.document, 'p1'), containsPair('x', 300));
      expect((itemOf(d.document, 'p2')['samples'] as Map)['x'], [32000, 48000]);
      expectNeighborsKept(doc, d.document, {'p1', 'p2', 'p3'});
      // Without space nothing is added.
      final blocked = rules.duplicate(doc, ['g1'], dx: 100, newId: newId);
      expect(blocked.accepted, isFalse);
      expect(itemsOf(blocked.document), hasLength(3));
    });

    test('an Instant room refuses kinds that it does not allow', () {
      final room = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [],
      }, schema: DocumentSchema('instant-room', 1));
      final d = rules.paste(room, [
        {...box('q1', 'task_card', 0, 0, 100, 100), 'task_id': 'task1'},
      ], newId: newId);
      expect(d.error?.code, 'kind_not_allowed');
      expect(d.accepted, isFalse);
    });

    test('a typed document has no placement edits', () {
      final typed = NoteDocument.fromJson({
        'blocks': [],
      }, schema: DocumentSchema('note-typed', 1));
      expect(
        rules.paste(typed, [text('c1', 0, 0)], newId: newId),
        rejected('operation', 'invalid_operation', []),
      );
    });
  });
}
