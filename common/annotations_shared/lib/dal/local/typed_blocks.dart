/// A simple typed note (headings, paragraphs and lists) as one Quill
/// document, and back (annotations#35, the phone editor).
///
/// Each block is one or more lines: a heading line carries `header` (1 to
/// 3 in the editor; levels 4 to 6 load and save as they are), a list item
/// line carries `list` (`ordered` or `bullet`), a paragraph line carries
/// nothing. The text of a line is the spans of the block, with the same
/// inline formatting as text blocks on paper. Saving keeps the ids of the
/// blocks in order of kind, so an unchanged block stays the same block.
library;

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import 'quill_text_engine.dart';

/// The kinds the phone editor writes; a typed note with only these is a
/// simple typed note.
const simpleTypedKinds = {'heading', 'paragraph', 'list'};

/// The Quill document of [blocks] (simple typed blocks only).
Delta blocksToDelta(List<Map<String, Object?>> blocks) {
  final delta = Delta();
  void line(List<Object?> spans, Map<String, dynamic>? attributes) {
    final text = spansToDelta(spans).toList();
    // spansToDelta ends with one plain line break; the block format goes on
    // that line break.
    for (final op in text.take(text.length - 1)) {
      delta.push(op);
    }
    final last = text.last;
    final data = last.data as String;
    if (data.length > 1) {
      delta.insert(data.substring(0, data.length - 1), last.attributes);
    }
    delta.insert('\n', attributes);
  }

  for (final b in blocks) {
    switch (b['kind']) {
      case 'heading':
        line((b['spans'] as List?) ?? const [], {'header': b['level']});
      case 'list':
        final ordered = b['ordered'] == true;
        for (final item in (b['items'] as List?) ?? const []) {
          line(((item as Map)['spans'] as List?) ?? const [], {
            'list': ordered ? 'ordered' : 'bullet',
          });
        }
      default:
        line((b['spans'] as List?) ?? const [], null);
    }
  }
  if (delta.isEmpty) delta.insert('\n');
  return delta;
}

/// The blocks of a Quill [document]. [previous] gives the ids to keep (in
/// order, per kind); [newId] makes the others.
List<Map<String, Object?>> documentToBlocks(
  Document document, {
  required List<Map<String, Object?>> previous,
  required String Function() newId,
}) {
  final ids = <String, List<String>>{};
  for (final b in previous) {
    (ids[b['kind'] as String] ??= []).add(b['id'] as String);
  }
  final used = <String, int>{};
  String idFor(String kind) {
    final n = used[kind] = (used[kind] ?? 0) + 1;
    final list = ids[kind];
    return list != null && n <= list.length ? list[n - 1] : newId();
  }

  final blocks = <Map<String, Object?>>[];
  // Lines, also those inside list containers, in document order.
  Iterable<Line> lines(Iterable<Node> nodes) sync* {
    for (final node in nodes) {
      if (node is Line) {
        yield node;
      } else if (node is Block) {
        yield* lines(node.children);
      }
    }
  }

  for (final node in lines(document.root.children)) {
    final style = node.style.attributes;
    // The line's text with a plain closing line break: Quill can join the
    // last text and the line break in one operation.
    final lineDelta = Delta();
    for (final op in node.toDelta().toList()) {
      final data = op.data;
      if (data is String && data.endsWith('\n')) {
        final text = data.substring(0, data.length - 1);
        if (text.isNotEmpty) lineDelta.insert(text, op.attributes);
      } else {
        lineDelta.push(op);
      }
    }
    lineDelta.insert('\n');
    final spans = deltaToSpans(lineDelta);
    final header = style[Attribute.header.key]?.value;
    final list = style[Attribute.list.key]?.value;
    if (header is int) {
      blocks.add({
        'id': idFor('heading'),
        'kind': 'heading',
        'level': header,
        'spans': spans,
      });
    } else if (list == 'ordered' || list == 'bullet') {
      final ordered = list == 'ordered';
      final last = blocks.isEmpty ? null : blocks.last;
      if (last != null &&
          last['kind'] == 'list' &&
          last['ordered'] == ordered &&
          last['open'] == true) {
        (last['items'] as List).add({'spans': spans});
      } else {
        blocks.add({
          'id': idFor('list'),
          'kind': 'list',
          'ordered': ordered,
          'items': [
            {'spans': spans},
          ],
          'open': true,
        });
      }
      continue;
    } else {
      blocks.add({
        'id': idFor('paragraph'),
        'kind': 'paragraph',
        'spans': spans,
      });
    }
    // A line that is not a list item ends the list before it.
    if (blocks.length > 1 && blocks[blocks.length - 2]['kind'] == 'list') {
      blocks[blocks.length - 2].remove('open');
    }
  }
  for (final b in blocks) {
    b.remove('open');
  }
  // An empty editor is an empty note, not one empty paragraph.
  if (blocks.length == 1 &&
      blocks.single['kind'] == 'paragraph' &&
      (blocks.single['spans'] as List).isEmpty &&
      previous.isEmpty) {
    return [];
  }
  return blocks;
}
