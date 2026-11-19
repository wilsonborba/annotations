// annotations#35: simple typed blocks to one Quill document and back.
import 'dart:convert';

import 'package:annotations_shared/dal/local/typed_blocks.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

final blocks = <Map<String, Object?>>[
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
      {'text': 'Plants make '},
      {'text': 'glucose', 'bold': true, 'color': '#1E40AFFF'},
      {'text': '.'},
    ],
  },
  {
    'id': 'l1',
    'kind': 'list',
    'ordered': false,
    'items': [
      {
        'spans': [
          {'text': 'light'},
        ],
      },
      {
        'spans': [
          {'text': 'water', 'italic': true},
        ],
      },
    ],
  },
  {'id': 'p2', 'kind': 'paragraph', 'spans': []},
  {
    'id': 'l2',
    'kind': 'list',
    'ordered': true,
    'items': [
      {
        'spans': [
          {'text': 'first'},
        ],
      },
    ],
  },
  {
    'id': 'h2',
    'kind': 'heading',
    'level': 5,
    'spans': [
      {'text': 'Small heading', 'size': 20},
    ],
  },
];

void main() {
  test('round trip keeps every block, id and format', () {
    final doc = Document.fromDelta(blocksToDelta(blocks));
    final back = documentToBlocks(doc, previous: blocks, newId: () => 'new');
    expect(jsonEncode(back), jsonEncode(blocks));
  });

  test('an empty note stays empty; new lines get new ids', () {
    final empty = Document.fromDelta(blocksToDelta(const []));
    expect(
      documentToBlocks(empty, previous: const [], newId: () => 'x'),
      isEmpty,
    );
    final doc = Document.fromDelta(blocksToDelta(blocks));
    doc.insert(doc.length - 1, '\nAnother line');
    var n = 0;
    final back = documentToBlocks(
      doc,
      previous: blocks,
      newId: () => 'n${n++}',
    );
    expect(back.length, blocks.length + 1);
    expect([for (final b in back) b['id']], contains('n0'));
  });
}
