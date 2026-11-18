/// The change of a page document since its base revision as one operation
/// (annotations#19, decision 32a104ee983b48ca995a7e7820839020 part C): a sync
/// sends this instead of the whole note, so its size follows the change.
///
/// The operation uses the format of the editor rules (`page`, `delete`,
/// `replace`, `add` in one `batch`) and gives the server exactly the current
/// document, including the drawing order: `add` appends, so from the first
/// place where the order changes (a new item in the middle, a moved item)
/// every later item is removed and added again in its current order.
library;

import 'dart:convert';

import '../models/note_document.dart';

typedef JsonObject = Map<String, Object?>;

/// The operation that turns [base] into [current], or null when nothing
/// changed. Typed documents have no item operations: they return null and a
/// sync sends their whole (small) document.
JsonObject? syncOperation(NoteDocument base, NoteDocument current) {
  if (base is! PaperDocument || current is! PaperDocument) return null;
  final b = base.toJson(), c = current.toJson();
  final steps = <JsonObject>[];
  if (jsonEncode(b['page']) != jsonEncode(c['page'])) {
    steps.add({'op': 'page', 'page': c['page']});
  }
  final baseItems = <String, Map>{
    for (final it in (b['items'] as List).cast<Map>()) it['id'] as String: it,
  };
  final currentItems = (c['items'] as List).cast<Map>();
  final currentIds = {for (final it in currentItems) it['id'] as String};
  // Removed items.
  for (final id in baseItems.keys) {
    if (!currentIds.contains(id)) steps.add({'op': 'delete', 'id': id});
  }
  // The kept base items in base order; the current list must follow it
  // until the first new or moved item (or a kind change, which cannot be a
  // replace).
  final kept = [
    for (final id in baseItems.keys)
      if (currentIds.contains(id)) id,
  ];
  var tail = currentItems.length;
  var j = 0;
  for (var k = 0; k < currentItems.length; k++) {
    final it = currentItems[k];
    final id = it['id'] as String;
    final before = baseItems[id];
    if (before == null ||
        j >= kept.length ||
        kept[j] != id ||
        before['kind'] != it['kind']) {
      tail = k;
      break;
    }
    j++;
    if (jsonEncode(before) != jsonEncode(it)) {
      steps.add({'op': 'replace', 'item': it});
    }
  }
  for (final it in currentItems.skip(tail)) {
    final id = it['id'] as String;
    if (baseItems.containsKey(id)) steps.add({'op': 'delete', 'id': id});
  }
  for (final it in currentItems.skip(tail)) {
    steps.add({'op': 'add', 'item': it});
  }
  if (steps.isEmpty) return null;
  return {'op': 'batch', 'steps': steps};
}
