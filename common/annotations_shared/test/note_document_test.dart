import 'dart:convert';
import 'dart:io';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:flutter_test/flutter_test.dart';

// Unchanged valid fixtures from wilsonborba/annotations_api at
// 5317abb5e5ec5f68bdf42d84e18a8c8d7440ade6, tests/fixtures/document_schema/valid.
// Schema1 includes compact stroke encoding (decision b593b780).
final fixtureDirectory = Directory('test/fixtures/document_schema/valid');
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('${fixtureDirectory.path}/$name.json').readAsStringSync())
        as Map<String, dynamic>;
NoteDocument decode(Map<String, dynamic> value) => NoteDocument.fromJson(
  value['document'],
  schema: DocumentSchema(
    value['family'] as String,
    value['schema_version'] as int,
  ),
);
List<DocumentItem> items(NoteDocument document) => switch (document) {
  PaperDocument() => document.items,
  TypedDocument() => document.blocks,
  OpaqueDocument() => [],
};
Matcher malformed(String code, String path) => throwsA(
  isA<DocumentFormatException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.path, 'path', path),
);

void main() {
  final fixtures =
      fixtureDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  test('canonical fixture set includes every family and item kind', () {
    expect(fixtures, hasLength(43));
    final kinds = <String, Set<String>>{};
    for (final file in fixtures) {
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final doc = decode(value);
      final familyKinds = kinds.putIfAbsent(
        value['family'] as String,
        () => <String>{},
      );
      for (final item in items(doc)) {
        familyKinds.add(item.kind);
        expect(item, isNot(isA<OpaqueItem>()));
      }
    }
    expect(kinds['note-original'], {
      'text',
      'image',
      'file_card',
      'link_card',
      'website_card',
      'youtube_card',
      'csv_table',
      'pdf_preview',
      'reports_embed',
      'task_card',
      'quiz_card',
      'group',
      'stroke',
      'shape',
    });
    expect(kinds['note-typed'], {
      'heading',
      'paragraph',
      'list',
      'table',
      'figure',
      'handwriting',
      'file_card',
      'link_card',
      'website_card',
      'youtube_card',
      'csv_table',
      'pdf_preview',
      'reports_embed',
      'task_card',
      'quiz_card',
    });
    expect(kinds['instant-room'], {
      'text',
      'image',
      'file_card',
      'link_card',
      'website_card',
      'youtube_card',
      'reports_embed',
      'group',
      'stroke',
      'shape',
    });
  });
  for (final file in fixtures) {
    test('backend roundtrip ${file.uri.pathSegments.last}', () {
      final value = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final document = decode(value);
      expect(document.toJson(), value['document']);
      expect(jsonEncode(document.toJson()), jsonEncode(value['document']));
      expect(
        NoteDocument.fromJson(
          document.toJson(),
          schema: document.schema,
        ).toJson(),
        value['document'],
      );
    });
  }

  test('typed access exposes compact units and three independent versions', () {
    final value = fixture('original-stroke-flat');
    final body = value['document'] as Map<String, dynamic>;
    (body['items'] as List).first['brush_version'] = 7;
    final document = decode(value) as OriginalDocument;
    final stroke = document.items.single as StrokeItem;
    final revision = NoteRevision(
      noteRevision: 31,
      revisionId: 'revision-31',
      document: document,
    );
    expect(revision.noteRevision, 31);
    expect(revision.document.schema.version, 1);
    expect(stroke.brushVersion, 7);
    expect(stroke.samples.x.first, 10000); // 100.00 page units.
    expect(stroke.samples.time, [0, 8, 16, 24, 32]); // Milliseconds.
    expect(stroke.samples.pressure!.first, 500); // 0.500 pressure.
    expect(stroke.samples.tilt!.first, 600); // 0.600 radians.
    expect(stroke.nodes.first.outgoing!.y, 29800);
    expect(stroke.width, 2.5);
    expect(stroke.tipAngle, 0.785);
    expect(document.toJson(), body);
    final noPressure =
        decode(fixture('original-stroke-no-pressure')) as OriginalDocument;
    final unpressured = noPressure.items.single as StrokeItem;
    expect(unpressured.samples.pressure, isNull);
    expect(unpressured.samples.toJson().containsKey('pressure'), isFalse);
  });

  test(
    'nested known types expose rich text, tables, handwriting and snapshots',
    () {
      final table =
          (decode(fixture('typed-table')) as TypedDocument).blocks.single
              as TableBlock;
      expect(table.rows[1].cells[1].spans.single.text, '7');
      final handwriting =
          (decode(fixture('typed-handwriting')) as TypedDocument).blocks.single
              as HandwritingBlock;
      expect(handwriting.ink.first, isA<StrokeItem>());
      expect(handwriting.ink[1], isA<RectangleShape>());
      expect(handwriting.width, 400);
      final snapshot =
          (decode(fixture('original-reports-embed-snapshot'))
                      as OriginalDocument)
                  .items
                  .single
              as ReportsEmbed;
      expect(snapshot.mode, 'snapshot');
      expect(snapshot.capturedAt, isA<int>());
      expect(snapshot.bounds, isNotNull);
      final typedCard =
          (decode(fixture('typed-file-card')) as TypedDocument).blocks.single
              as FileCard;
      expect(typedCard.bounds, isNull);
      expect(typedCard.fileId, 'file-doc-1');
    },
  );

  test('unknown nested fields and kinds survive known family load/save', () {
    final value = fixture('original-text');
    final body = value['document'] as Map<String, dynamic>;
    body['future_root'] = {
      'nested': [
        null,
        1.0,
        false,
        {'opaque': 'keep'},
      ],
    };
    final page = body['page'] as Map<String, dynamic>;
    page['future_page'] = null;
    (page['background'] as Map)['future_background'] = ['keep', null];
    final list = body['items'] as List;
    list.first['future_item'] = {'new': true};
    list.first['spans'][0]['future_style'] = {
      'payload': [42, null],
    };
    list.add({
      'kind': 'future-mesh',
      'content': {
        'vertices': [1, 2, 3],
      },
      'id': null,
    });
    final document = decode(value) as OriginalDocument;
    expect(document.items.last, isA<OpaqueItem>());
    expect(document.items.last.id, isNull);
    expect(document.toJson(), body);
    expect(document.items.first.toJson()['future_item'], {'new': true});
  });

  test('unknown handwriting ink and fields inside table cells survive', () {
    final hand = fixture('typed-handwriting');
    final ink = hand['document']['blocks'][0]['ink'] as List;
    ink.add({
      'kind': 'future-ink',
      'future': {'a': null},
    });
    ink.first['samples']['future_device_column'] = [null, 'opaque'];
    ink.first['nodes'][0]['future_handle'] = {
      'z': [1.5],
    };
    expect(decode(hand).toJson(), hand['document']);
    final table = fixture('typed-table');
    table['document']['blocks'][0]['rows'][0]['cells'][0]['future_formula'] = [
      null,
      true,
    ];
    table['document']['blocks'][0]['rows'][0]['future_row'] = 'keep';
    expect(decode(table).toJson(), table['document']);
  });

  test('newer schemas and unknown families stay entirely opaque', () {
    for (final schema in [
      DocumentSchema('note-original', 2),
      DocumentSchema('note-typed', 8),
      DocumentSchema('instant-room', 2),
      DocumentSchema('future-family', 1),
    ]) {
      final body = {
        'page': 'new page format',
        'items': {
          'new': [null, 42],
        },
        'future': true,
      };
      final document = NoteDocument.fromJson(body, schema: schema);
      expect(document, isA<OpaqueDocument>());
      expect(document.toJson(), body);
      expect(document.schema, same(schema));
    }
  });

  test('unknown shape and background variants remain opaque', () {
    final value = fixture('original-shape-circle');
    value['document']['items'][0] = {
      'id': 'shape1',
      'kind': 'shape',
      'shape': 'future-solid',
      'opaque_geometry': [null, 3],
    };
    value['document']['page']['background'] = {
      'kind': 'future-paper',
      'shader': {'a': 3},
    };
    final document = decode(value) as OriginalDocument;
    expect(document.items.single, isA<OpaqueItem>());
    expect(document.page.background.kind, 'future-paper');
    expect(document.toJson(), value['document']);
  });

  test(
    'absent optional fields and explicit nulls are not conflated on save',
    () {
      final value = fixture('typed-website-card');
      final card = value['document']['blocks'][0] as Map;
      card.remove('description');
      card['title'] = null;
      card['future'] = null;
      final document = decode(value) as TypedDocument;
      final website = document.blocks.single as WebsiteCard;
      expect(website.title, isNull);
      expect(website.description, isNull);
      final output = (document.toJson()['blocks'] as List).single as Map;
      expect(output.containsKey('title'), isTrue);
      expect(output['title'], isNull);
      expect(output.containsKey('description'), isFalse);
      expect(output.containsKey('future'), isTrue);
      expect(document.toJson(), value['document']);
    },
  );

  test(
    'model snapshots and returned collections cannot mutate stored content',
    () {
      final value = fixture('original-stroke-round');
      final expected = jsonDecode(jsonEncode(value['document']));
      final document = decode(value) as OriginalDocument;
      value['document']['items'][0]['samples']['x'][0] = 999;
      final output = document.toJson();
      (output['items'] as List).first['samples']['x'][0] = 777;
      final stroke = document.items.single as StrokeItem;
      expect(document.toJson(), expected);
      expect(() => document.items.clear(), throwsUnsupportedError);
      expect(() => stroke.samples.x[0] = 5, throwsUnsupportedError);
      expect(() => stroke.nodes.clear(), throwsUnsupportedError);
      expect(stroke.samples.x.first, 10000);
    },
  );

  test('malformed known fields fail with safe precise paths', () {
    final cases = <(String, void Function(Map<String, dynamic>), String, String)>[
      (
        'original-text',
        (v) => (v['document'] as Map).remove('page'),
        'missing_field',
        'page',
      ),
      (
        'original-text',
        (v) => v['document']['items'][0]['width'] = 'private content',
        'invalid_type',
        'items[0].width',
      ),
      (
        'original-text',
        (v) => v['document']['items'][0]['spans'][0]['bold'] = 1,
        'invalid_type',
        'items[0].spans[0].bold',
      ),
      (
        'original-stroke-flat',
        (v) => v['document']['items'][0]['samples']['x'][0] = 10.5,
        'invalid_type',
        'items[0].samples.x[0]',
      ),
      (
        'original-stroke-flat',
        (v) => (v['document']['items'][0]['samples']['pressure'] as List)
            .removeLast(),
        'invalid_count',
        'items[0].samples.pressure',
      ),
      (
        'original-stroke-flat',
        (v) => v['document']['items'][0]['nodes'][0]['out']['x'] = 'bad',
        'invalid_type',
        'items[0].nodes[0].out.x',
      ),
      (
        'original-reports-embed-snapshot',
        (v) => (v['document']['items'][0] as Map).remove('captured_at'),
        'missing_field',
        'items[0].captured_at',
      ),
      (
        'typed-handwriting',
        (v) => v['document']['blocks'][0]['ink'] = {},
        'invalid_type',
        'blocks[0].ink',
      ),
      (
        'typed-table',
        (v) =>
            v['document']['blocks'][0]['rows'][0]['cells'][0]['spans'][0]['text'] =
                false,
        'invalid_type',
        'blocks[0].rows[0].cells[0].spans[0].text',
      ),
    ];
    for (final (name, change, code, path) in cases) {
      final value = fixture(name);
      change(value);
      expect(() => decode(value), malformed(code, path), reason: '$name $path');
    }
    expect(
      () => NoteDocument.fromJson([], schema: DocumentSchema('note-typed', 1)),
      malformed('invalid_type', ''),
    );
    expect(
      () => NoteDocument.fromJson({
        'blocks': [],
        'extra': double.infinity,
      }, schema: DocumentSchema('note-typed', 1)),
      malformed('invalid_json', ''),
    );
  });
}
