import 'dart:convert';
import 'dart:typed_data';

import 'package:annotations_shared/dal/local/quill_text_engine.dart';
import 'package:annotations_shared/dal/local/system_clipboard.dart';
import 'package:annotations_shared/dal/local/text_engine.dart';
import 'package:annotations_shared/domain/models/ink.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:annotations_shared/domain/services/object_clipboard.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/domain/services/rich_paste.dart';
import 'package:flutter_test/flutter_test.dart';

NoteDocument paper(List<Object?> items, {String family = 'note-original'}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': items,
    }, schema: DocumentSchema(family, 1));

Map<String, Object?> text(String id, num x, num y, {String? body}) => {
  'id': id,
  'kind': 'text',
  'x': x,
  'y': y,
  'width': 200,
  'height': 100,
  'spans': [
    {'text': body ?? 'Block $id'},
  ],
};

Map<String, Object?> image(String id, num x, num y) => {
  'id': id,
  'kind': 'image',
  'x': x,
  'y': y,
  'width': 100,
  'height': 100,
  'file_id': 'f_$id',
};

Map<String, Object?> stroke(String id, num x0, num y0, num x1, num y1) {
  int h(num v) => (v * 100).round();
  return {
    'id': id,
    'kind': 'stroke',
    'tool': 'round',
    'brush_version': 1,
    'width': 2,
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

/// A system clipboard in memory that records every write.
final class FakeSystemClipboard implements SystemClipboard {
  String? text, html;
  Uint8List? picture;
  var writes = 0;

  @override
  Future<void> writeText(String value) async {
    writes++;
    text = value;
    picture = null;
    html = null;
  }

  @override
  Future<bool> writeImage(Uint8List bytes) async {
    writes++;
    picture = bytes;
    text = null;
    html = null;
    return true;
  }

  @override
  Future<String?> readText() async => text;
  @override
  Future<String?> readHtml() async => html;
  @override
  Future<Uint8List?> readImage() async => picture;

  /// Another app copies.
  void external({String? text, String? html, Uint8List? picture}) {
    this.text = text;
    this.html = html;
    this.picture = picture;
  }
}

final class FakeFiles implements ClipboardFiles {
  final denied = <String>{};
  final stored = <String>[];
  final discarded = <String>[];
  final pictures = <String, Uint8List>{};
  var checked = 0;

  @override
  Future<bool> canUse(NoteDocument document, String fileId) async {
    checked++;
    return !denied.contains(fileId);
  }

  @override
  Future<Uint8List?> pictureBytes(String fileId) async => pictures[fileId];

  @override
  Future<StoredPicture?> storePicture(
    NoteDocument document,
    Uint8List bytes,
  ) async {
    final id = 'stored${stored.length + 1}';
    stored.add(id);
    return StoredPicture(id, 400, 200);
  }

  @override
  Future<void> discardPicture(String fileId) async => discarded.add(fileId);
}

/// Text height: 20 page units per line.
final class FakeEngine implements TextEngine {
  @override
  String get name => 'fake';
  @override
  String get version => '0';
  @override
  TextContent load(List<Object?> spans) => throw UnimplementedError();
  @override
  num measureHeight(List<Object?> spans, num width) {
    final t = [for (final s in spans) (s as Map)['text']].join();
    return 20 * ('\n'.allMatches(t).length + 1);
  }
}

void main() {
  const selector = ObjectSelector();
  late FakeSystemClipboard system;
  late FakeFiles files;
  late ObjectClipboard clipboard;
  late ObjectActions actions;
  var n = 0;
  String newId() => 'n${++n}';

  setUp(() {
    n = 0;
    system = FakeSystemClipboard();
    files = FakeFiles();
    clipboard = ObjectClipboard(
      system: system,
      files: files,
      engine: FakeEngine(),
      newId: newId,
    );
    actions = ObjectActions(newId: newId);
  });

  group('selection', () {
    final doc = paper([
      text('t1', 0, 0),
      stroke('s1', 10, 50, 150, 50), // free ink over the text
      text('t2', 400, 0),
      stroke('s2', 420, 150, 560, 150),
      groupItem('g1', ['t2', 's2']),
      stroke('s3', 50, 400, 150, 420),
      stroke('s4', 60, 430, 140, 440),
      groupItem('g2', ['s3', 's4']), // drawing only
    ]);

    test('Type mode reaches the text under ink; Draw mode only drawing', () {
      expect(selector.hit(doc, const InkVec(50, 50), SelectionTool.type), 't1');
      expect(selector.hit(doc, const InkVec(50, 50), SelectionTool.draw), 's1');
      expect(selector.hit(doc, const InkVec(50, 80), SelectionTool.draw), null);
      expect(
        selector.hit(doc, const InkVec(700, 700), SelectionTool.type),
        null,
      );
    });

    test('a member selects its whole group', () {
      expect(
        selector.hit(doc, const InkVec(450, 50), SelectionTool.type),
        'g1',
      );
      expect(selector.select(doc, 's2').ids, ['g1']);
      // Ink grouped with a block is not drawing for Draw mode.
      expect(
        selector.hit(doc, const InkVec(500, 150), SelectionTool.draw),
        isNull,
      );
      expect(
        selector.hit(doc, const InkVec(100, 410), SelectionTool.draw),
        'g2',
      );
    });

    test('modifier adds and removes; select all; prune', () {
      var s = selector.select(doc, 't1');
      s = selector.toggle(doc, s, 't2');
      expect(s.ids, ['t1', 'g1']);
      s = selector.toggle(doc, s, 't1');
      expect(s.ids, ['g1']);
      expect(selector.all(doc).ids, ['t1', 's1', 'g1', 'g2']);
      expect(selector.all(doc, tool: SelectionTool.draw).ids, ['s1', 'g2']);
      final after = paper([text('t1', 0, 0)]);
      expect(selector.prune(after, ObjectSelection(['t1', 'g1'])).ids, ['t1']);
    });

    test('a box selects objects completely inside it', () {
      final s = selector.box(doc, const InkVec(-1, -1), const InkVec(300, 300));
      expect(s.ids, ['t1', 's1']);
      final draw = selector.box(
        doc,
        const InkVec(-1, -1),
        const InkVec(1000, 1000),
        tool: SelectionTool.draw,
      );
      expect(draw.ids, ['s1', 'g2']);
    });

    test('the lasso selects drawing only, never text under it', () {
      const lasso = [
        InkVec(-5, -5),
        InkVec(300, -5),
        InkVec(300, 500),
        InkVec(-5, 500),
      ];
      expect(selector.lasso(doc, lasso).ids, ['s1', 'g2']);
    });

    test('text focus and object focus never mix', () {
      const EditorFocus text = TextFocus('t1');
      final EditorFocus objects = ObjectFocus(ObjectSelection(['t1']));
      expect(text, isNot(isA<ObjectFocus>()));
      expect(objects, isNot(isA<TextFocus>()));
    });
  });

  group('internal copy and paste', () {
    final doc = paper([
      text('t1', 0, 0),
      stroke('s1', 20, 120, 180, 150),
      groupItem('g1', ['t1', 's1']),
      text('t2', 500, 0),
    ]);

    test('a group keeps member layout and gets new ids', () async {
      final session = NotesEditor(doc);
      final copied = await clipboard.copy(session, ObjectSelection(['g1']));
      expect(copied!.units, ['g1']);
      expect(system.text, 'Block t1');
      final edit = await clipboard.paste(
        session,
        const InkVec(0, 300),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isTrue, reason: '${edit.error}');
      expect(edit.selection.ids, ['n3']);
      final d = session.document;
      expect(itemOf(d, 'n3')['members'], ['n1', 'n2']);
      expect(itemOf(d, 'n1'), containsPair('y', 300));
      expect(itemOf(d, 'n1'), containsPair('x', 0));
      expect((itemOf(d, 'n2')['samples'] as Map)['y'], [42000, 45000]);
      expect((itemOf(d, 'n2')['nodes'] as List).first, containsPair('x', 2000));
      // The copy is still editable ink with the same fields.
      final source = itemOf(doc, 's1'), copy = itemOf(d, 'n2');
      for (final k in ['tool', 'brush_version', 'width', 'color']) {
        expect(copy[k], source[k]);
      }
      expect(itemsOf(d).take(4).toList(), itemsOf(doc));
      expect(session.stepsBack, 1);
    });

    test('a paste that does not fit changes nothing; clipboard kept', () async {
      final session = NotesEditor(doc);
      await clipboard.copy(session, ObjectSelection(['g1']));
      final before = jsonEncode(clipboard.content!.items);
      final writes = system.writes;
      final edit = await clipboard.paste(
        session,
        const InkVec(400, 50),
        ObjectSelection(['t2']),
      );
      expect(edit.accepted, isFalse);
      expect(edit.error?.rule, 'group_overlap');
      expect(edit.selection.ids, ['t2']);
      expect(jsonEncode(session.document.toJson()), jsonEncode(doc.toJson()));
      expect(session.stepsBack, 0);
      expect(jsonEncode(clipboard.content!.items), before);
      expect(system.writes, writes);
      expect(system.text, 'Block t1');
      // The same clipboard pastes later where it fits.
      final ok = await clipboard.paste(
        session,
        const InkVec(0, 300),
        ObjectSelection.empty,
      );
      expect(ok.accepted, isTrue);
    });

    test('paste keeps the copy inside the page width', () async {
      final session = NotesEditor(doc);
      await clipboard.copy(session, ObjectSelection(['t2']));
      final edit = await clipboard.paste(
        session,
        const InkVec(950, 400),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isTrue);
      expect(itemOf(session.document, 'n1'), containsPair('x', 800));
    });

    test('paste checks access to referenced files', () async {
      final session = NotesEditor(paper([image('i1', 0, 0)]));
      await clipboard.copy(session, ObjectSelection(['i1']));
      files.denied.add('f_i1');
      final edit = await clipboard.paste(
        session,
        const InkVec(0, 300),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isFalse);
      expect(edit.error?.code, 'file_access');
      expect(edit.error?.items, ['i1']);
      expect(itemsOf(session.document), hasLength(1));
      files.denied.clear();
      final ok = await clipboard.paste(
        session,
        const InkVec(0, 300),
        ObjectSelection.empty,
      );
      expect(ok.accepted, isTrue);
      expect(itemOf(session.document, 'n1'), containsPair('file_id', 'f_i1'));
    });

    test('Instant pastes without history', () async {
      final notes = NotesEditor(doc);
      await clipboard.copy(notes, ObjectSelection(['g1']));
      final room = InstantEditor(
        paper([], family: 'instant-room') as InstantRoomDocument,
      );
      final edit = await clipboard.paste(
        room,
        const InkVec(0, 0),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isTrue);
      expect(itemsOf(room.document), hasLength(3));
    });
  });

  group('cut', () {
    test('cut copies and deletes as one step; undo restores', () async {
      final doc = paper([text('t1', 0, 0), text('t2', 300, 0)]);
      final session = NotesEditor(doc);
      final edit = await clipboard.cut(session, ObjectSelection(['t1']));
      expect(edit.accepted, isTrue);
      expect(edit.selection.isEmpty, isTrue);
      expect(itemsOf(session.document).map((it) => it['id']), ['t2']);
      expect(clipboard.content!.units, ['t1']);
      expect(session.undo().moved, isTrue);
      expect(jsonEncode(session.document.toJson()), jsonEncode(doc.toJson()));
    });

    test('a rejected cut keeps the source and the clipboard', () async {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
      ]);
      final session = NotesEditor(doc);
      system.external(text: 'other app');
      // A member alone cannot leave its group of two.
      final edit = await clipboard.cut(session, ObjectSelection(['t1']));
      expect(edit.accepted, isFalse);
      expect(edit.selection.ids, ['t1']);
      expect(jsonEncode(session.document.toJson()), jsonEncode(doc.toJson()));
      expect(clipboard.content, isNull);
      expect(system.writes, 0);
      expect(system.text, 'other app');
      expect(session.stepsBack, 0);
    });
  });

  group('copy to other apps', () {
    test('text goes as plain text in reading order', () async {
      final session = NotesEditor(
        paper([
          text('b', 300, 200, body: 'third'),
          text('a', 300, 0, body: 'second'),
          text('c', 0, 0, body: 'first'),
          stroke('s1', 10, 400, 50, 400),
        ]),
      );
      await clipboard.copy(session, selector.all(session.document));
      expect(system.text, 'first\n\nsecond\n\nthird');
    });

    test('a picture goes as a picture', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      files.pictures['f_i1'] = bytes;
      final session = NotesEditor(paper([image('i1', 0, 0)]));
      await clipboard.copy(session, ObjectSelection(['i1']));
      expect(system.picture, bytes);
      expect(system.text, isNull);
      // The app still pastes its own copy (a whole object with its file).
      final edit = await clipboard.paste(
        session,
        const InkVec(0, 200),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isTrue);
      expect(files.stored, isEmpty);
      expect(files.checked, 1);
    });

    test('ink alone writes empty text and pastes internally', () async {
      final session = NotesEditor(paper([stroke('s1', 10, 10, 50, 10)]));
      system.external(text: 'old');
      await clipboard.copy(session, ObjectSelection(['s1']));
      expect(system.text, '');
      final edit = await clipboard.paste(
        session,
        const InkVec(10, 100),
        ObjectSelection.empty,
      );
      expect(itemOf(session.document, 'n1')['kind'], 'stroke');
      expect(edit.selection.ids, ['n1']);
    });
  });

  group('paste from other apps', () {
    test('a later copy in another app wins over the internal copy', () async {
      final session = NotesEditor(paper([text('t1', 0, 0)]));
      await clipboard.copy(session, ObjectSelection(['t1']));
      system.external(
        text: 'ignored',
        html:
            '<p>Hello <b>bold</b><script>alert(1)</script>'
            '<img src="https://example.org/x.png"></p>'
            '<p style="color: rgb(255, 0, 0)">red</p>',
      );
      final edit = await clipboard.paste(
        session,
        const InkVec(0, 200),
        ObjectSelection(['t1']),
      );
      expect(edit.accepted, isTrue, reason: '${edit.error}');
      expect(edit.selection.ids, ['n1']);
      final item = itemOf(session.document, 'n1');
      expect(item['kind'], 'text');
      expect(item['spans'], [
        {'text': 'Hello '},
        {'text': 'bold', 'bold': true},
        {'text': '\n'},
        {'text': 'red', 'color': '#FF0000FF'},
      ]);
      expect(item['height'], 40);
      expect(item['width'], 400);
      expect(files.stored, isEmpty);
    });

    test('plain text keeps its characters', () async {
      final session = NotesEditor(paper([]));
      system.external(text: '  a\tb\n\n\nc\u0007 ');
      final edit = await clipboard.paste(
        session,
        const InkVec(800, 0),
        ObjectSelection.empty,
      );
      final item = itemOf(session.document, 'n1');
      expect(edit.accepted, isTrue);
      expect(item['spans'], [
        {'text': '  a\tb\n\n\nc '},
      ]);
      // Kept inside the page width.
      expect(item['x'], 600);
    });

    test('external text that does not fit adds nothing', () async {
      final doc = paper([text('t1', 0, 0)]);
      final session = NotesEditor(doc);
      system.external(text: 'hello');
      final edit = await clipboard.paste(
        session,
        const InkVec(100, 50),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isFalse);
      expect(edit.error?.rule, 'block_overlap');
      expect(jsonEncode(session.document.toJson()), jsonEncode(doc.toJson()));
      expect(system.text, 'hello');
    });

    test('a picture becomes an image; a rejected one is discarded', () async {
      final doc = paper([text('t1', 0, 0)]);
      final session = NotesEditor(doc);
      system.external(picture: Uint8List.fromList([9]));
      final blocked = await clipboard.paste(
        session,
        const InkVec(100, 0),
        ObjectSelection.empty,
      );
      expect(blocked.accepted, isFalse);
      expect(files.discarded, ['stored1']);
      expect(itemsOf(session.document), hasLength(1));
      final edit = await clipboard.paste(
        session,
        const InkVec(0, 200),
        ObjectSelection.empty,
      );
      expect(edit.accepted, isTrue);
      expect(itemOf(session.document, edit.selection.ids.single), {
        'id': 'n2',
        'kind': 'image',
        'x': 0,
        'y': 200,
        'width': 400,
        'height': 200,
        'file_id': 'stored2',
      });
    });

    test('rich text for a focused text block keeps its formatting', () async {
      system.external(html: '<i>new</i>');
      final spans = await clipboard.readExternalText();
      const engine = QuillTextEngine();
      final content = engine.load([
        {'text': 'one two', 'bold': true},
      ]);
      expect(insertSpans(content, 4, 3, spans!), [
        {'text': 'one ', 'bold': true},
        {'text': 'new', 'italic': true},
      ]);
    });
  });

  group('sanitizer', () {
    test('drops scripts, styles, media and forms without fetching', () {
      final spans = sanitizeHtml(
        '<html><head><style>p{color:red}</style>'
        '<link rel="stylesheet" href="https://example.org/a.css"></head>'
        '<body><p onclick="x()">A<iframe src="https://example.org"></iframe>'
        '<svg><text>no</text></svg><input value="no">'
        '<a href="javascript:alert(1)">link</a></p></body></html>',
      );
      expect(spans, [
        {'text': 'Alink'},
      ]);
    });

    test('maps the supported formatting only', () {
      expect(
        sanitizeHtml(
          '<span style="font-weight: 700; font-size: 40px">b</span>'
          '<em>i</em><del>s</del><span style="color:#0f08">c</span>'
          '<u>u</u>',
        ),
        [
          {'text': 'b', 'bold': true},
          {'text': 'i', 'italic': true},
          {'text': 's', 'strikethrough': true},
          {'text': 'c', 'color': '#00FF0088'},
          {'text': 'u'},
        ],
      );
    });

    test('keeps lines and table cells; reads Windows clipboard HTML', () {
      expect(
        sanitizeHtml(
          'Version:0.9\r\nStartHTML:0000000105\r\n'
          '<html><body><!--StartFragment--><table><tr><td>a</td><td>b</td>'
          '</tr><tr><td>c</td></tr></table><!--EndFragment--></body></html>',
        ),
        [
          {'text': 'a\tb\nc'},
        ],
      );
      expect(sanitizeHtml('<p>one</p><p></p><p></p><p>two<br>three</p>'), [
        {'text': 'one\ntwo\nthree'},
      ]);
    });
  });

  group('object actions', () {
    test('group keeps members; a conflict is rejected; undo restores', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 300, 150),
        text('t2', 250, 0),
      ]);
      final session = NotesEditor(doc);
      // The outside rectangle of t1 and s1 would overlap t2.
      final blocked = actions.group(session, ObjectSelection(['t1', 's1']));
      expect(blocked.accepted, isFalse);
      expect(blocked.error?.rule, 'group_overlap');
      expect(blocked.selection.ids, ['t1', 's1']);
      expect(session.stepsBack, 0);

      final ok = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        text('t2', 250, 0),
      ]);
      final s2 = NotesEditor(ok);
      final edit = actions.group(s2, ObjectSelection(['s1', 't1']));
      expect(edit.accepted, isTrue);
      expect(edit.selection.ids, ['n2']);
      expect(itemOf(s2.document, 'n2')['members'], ['t1', 's1']);
      expect(itemsOf(s2.document).take(3).toList(), itemsOf(ok));
      expect(s2.undo().moved, isTrue);
      expect(jsonEncode(s2.document.toJson()), jsonEncode(ok.toJson()));
    });

    test('ungroup keeps positions and selects the members', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
        text('t2', 500, 0),
      ]);
      final session = NotesEditor(doc);
      final edit = actions.ungroup(session, ObjectSelection(['g1', 't2']));
      expect(edit.accepted, isTrue);
      expect(edit.selection.ids, ['t1', 's1', 't2']);
      expect(
        itemsOf(session.document),
        itemsOf(doc).where((it) {
          return it['id'] != 'g1';
        }).toList(),
      );
      expect(actions.ungroup(session, ObjectSelection(['t2'])).decision, null);
    });

    test('delete removes a group with its members', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
        text('t2', 500, 0),
      ]);
      final session = NotesEditor(doc);
      final edit = actions.delete(session, ObjectSelection(['g1']));
      expect(edit.accepted, isTrue);
      expect(itemsOf(session.document).map((it) => it['id']), ['t2']);
      session.undo();
      expect(jsonEncode(session.document.toJson()), jsonEncode(doc.toJson()));
    });

    test('duplicate places copies below; without space adds nothing', () {
      final doc = paper([
        text('t1', 0, 0),
        stroke('s1', 20, 120, 180, 150),
        groupItem('g1', ['t1', 's1']),
      ]);
      final session = NotesEditor(doc);
      final edit = actions.duplicate(session, ObjectSelection(['g1']));
      expect(edit.accepted, isTrue);
      expect(edit.selection.ids, ['n3']);
      // Bounds height 150 plus the 16 unit gap.
      expect(itemOf(session.document, 'n1'), containsPair('y', 166));
      expect(itemOf(session.document, 'n3')['members'], ['n1', 'n2']);

      final full = paper([text('t1', 0, 0), text('t2', 0, 110)]);
      final s2 = NotesEditor(full);
      final blocked = actions.duplicate(s2, ObjectSelection(['t1']));
      expect(blocked.accepted, isFalse);
      expect(jsonEncode(s2.document.toJson()), jsonEncode(full.toJson()));
      expect(s2.stepsBack, 0);
    });
  });
}
