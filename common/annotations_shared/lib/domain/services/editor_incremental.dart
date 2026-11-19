part of 'editor_rules.dart';

// annotations#62: an edit checks only the items it names.
//
// A paper document that passed the full check keeps what the full check
// learned about the whole note: its size, its ids, the ids inside groups
// and the occupied cells of the top-level collision units. An operation on
// that document then checks only its own items against them. When anything
// looks wrong, or the operation changes the page or a group, the full check
// runs instead, so a rejection has exactly the code and path of the full
// check and the shared fixtures keep their verdicts. The full check also
// stays on load, before sync and on the server.

/// The facts of a document that passed the full check with [limits].
final class _Checked {
  _Checked(this.limits, this.bytes, this.ids, this.grouped, this.top);
  final NoteLimits limits;

  /// UTF-8 bytes of the whole document JSON.
  final int bytes;
  final Set<String> ids;

  /// Groups and every item inside a group.
  final Set<String> grouped;

  /// The occupied cells of each top-level collision unit, by id.
  final Map<String, EditorRect> top;
}

final _checked = Expando<_Checked>('editor rules check');

/// The facts of [document] when it passed the full check with [limits].
_Checked? _known(NoteDocument document, NoteLimits limits) {
  final info = _checked[document];
  if (info == null) return null;
  final l = info.limits;
  return identical(l, limits) ||
          (l.maxItems == limits.maxItems &&
              l.maxSamplesPerStroke == limits.maxSamplesPerStroke &&
              l.maxNodesPerStroke == limits.maxNodesPerStroke &&
              l.maxDocumentBytes == limits.maxDocumentBytes)
      ? info
      : null;
}

/// How many edits the changed-items check decided. Read by tests only.
int debugIncrementalChecks = 0;

int _byteLength(Object? json) => utf8.encode(jsonEncode(json)).length;

/// Records what the full check of [document] found.
void _remember(
  PaperDocument document,
  NoteLimits limits,
  _Ctx ctx,
  _Layout layout,
) {
  final grouped = <String>{};
  for (final (id, _, members) in ctx.groups) {
    grouped.add(id);
    for (final (m, _) in members) {
      grouped.add(m);
    }
  }
  final top = <String, EditorRect>{};
  for (var i = 0; i < layout.items.length; i++) {
    if (layout.grouped[i] || !layout._collides(i)) continue;
    if (layout.rect(i)?.cells case final cells?) {
      top[layout.items[i]['id'] as String] = cells;
    }
  }
  _checked[document] = _Checked(
    limits,
    ctx.bytes,
    ctx.ids.keys.toSet(),
    grouped,
    top,
  );
}

/// The decision for [op] on [base] from its changed items only, or null
/// when the full check has to decide.
EditDecision? _incremental(PaperDocument base, Object? op, NoteLimits limits) {
  final info = _known(base, limits);
  if (info == null || op is! Map) return null;
  final List<Object?> steps;
  if (op['op'] == 'batch') {
    if (op.length != 2 || op['steps'] is! List) return null;
    steps = op['steps'] as List<Object?>;
    // A long batch (a sync, a large paste) is cheaper as one full check.
    if (steps.isEmpty || steps.length > 64) return null;
  } else {
    steps = [op];
  }
  final items = List<Object?>.of(base.itemsJson);
  final fresh = Set<Object?>.identity();
  final removed = <Map>[];
  int? find(Object? id) {
    if (id is! String) return null;
    final i = items.indexWhere((it) => (it as Map)['id'] == id);
    return i < 0 ? null : i;
  }

  void drop(Object? item) {
    if (!fresh.remove(item)) removed.add(item as Map);
  }

  for (final step in steps) {
    if (step is! Map<String, Object?>) return null;
    switch (step['op']) {
      case 'add' when step.length == 2 && step['item'] is Map<String, Object?>:
        final item = step['item'];
        items.add(item);
        fresh.add(item);
      case 'replace'
          when step.length == 2 && step['item'] is Map<String, Object?>:
        final item = step['item'] as Map<String, Object?>;
        final i = find(item['id']);
        if (i == null || (items[i] as Map)['kind'] != item['kind']) return null;
        drop(items[i]);
        items[i] = item;
        fresh.add(item);
      case 'update'
          when step.length == 3 && step['changes'] is Map<String, Object?>:
        final changes = step['changes'] as Map<String, Object?>;
        final i = find(step['id']);
        if (i == null ||
            changes.containsKey('id') ||
            changes.containsKey('kind')) {
          return null;
        }
        final item = Map<String, Object?>.of(items[i] as Map<String, Object?>);
        for (final MapEntry(:key, :value) in changes.entries) {
          value == null ? item.remove(key) : item[key] = value;
        }
        drop(items[i]);
        items[i] = item;
        fresh.add(item);
      case 'delete' when step.length == 2:
        final i = find(step['id']);
        if (i == null) return null;
        drop(items.removeAt(i));
      default:
        // A page change, or anything unusual: the full check decides.
        return null;
    }
  }
  return _incrementalItems(base, info, items, fresh, removed, limits, op);
}

/// The decision for the item list [items] of [document]: the same objects
/// as its stored items where unchanged, new JSON elsewhere. Null when the
/// full check has to decide.
EditDecision? _incrementalList(
  PaperDocument document,
  List<Object?> items,
  NoteLimits limits,
) {
  final info = _known(document, limits);
  if (info == null) return null;
  final stored = Set<Object?>.identity()..addAll(document.itemsJson);
  final kept = Set<Object?>.identity();
  final fresh = Set<Object?>.identity();
  for (final it in items) {
    if (it is! Map<String, Object?>) return null;
    if (stored.contains(it)) {
      if (!kept.add(it)) return null;
    } else {
      fresh.add(it);
    }
  }
  final removed = [
    for (final it in document.itemsJson)
      if (!kept.contains(it)) it,
  ];
  return _incrementalItems(document, info, items, fresh, removed, limits, null);
}

EditDecision? _incrementalItems(
  PaperDocument base,
  _Checked info,
  List<Object?> items,
  Set<Object?> fresh,
  List<Map> removed,
  NoteLimits limits,
  Object? op,
) {
  if (items.length > limits.maxItems) return null;
  final changed = [
    for (var i = 0; i < items.length; i++)
      if (fresh.contains(items[i])) (i, items[i] as Map<String, Object?>),
  ];
  final removedIds = {for (final it in removed) it['id'] as String};
  for (final it in removed) {
    if (it['kind'] == 'group' || info.grouped.contains(it['id'])) return null;
  }
  // Size: the stored items are joined by commas inside the document.
  var bytes = info.bytes;
  final before = base.itemsJson.length;
  bytes += math.max(0, items.length - 1) - math.max(0, before - 1);
  for (final it in removed) {
    bytes -= _byteLength(it);
  }
  for (final (_, it) in changed) {
    bytes += _byteLength(it);
  }
  if (bytes > limits.maxDocumentBytes) return null;
  // Each changed item: the schema, its id, the grid and the collisions.
  final ctx = _Ctx(base.schema.family!, limits);
  final area = _Area(base.page.width, null);
  final cells = <String, EditorRect>{};
  for (final (i, it) in changed) {
    final id = it['id'];
    if (it['kind'] == 'group' || id is! String) return null;
    if (info.ids.contains(id) && !removedIds.contains(id)) return null;
    try {
      ctx.paperItem(it, 'items[$i]', area);
    } on DocumentFormatException {
      return null;
    }
    if (_role(it) != _Role.block) continue;
    for (final key in [
      'x',
      'y',
      'width',
      if (EditorGrid.areaKinds.contains(it['kind'])) 'height',
    ]) {
      if (it[key] case final num v when !EditorGrid.isOn(v)) return null;
    }
    final own = _blockRect(it)?.cells;
    if (own == null) continue;
    for (final MapEntry(:key, :value) in info.top.entries) {
      if (key != id && !removedIds.contains(key) && own.overlaps(value)) {
        return null;
      }
    }
    for (final other in cells.values) {
      if (own.overlaps(other)) return null;
    }
    cells[id] = own;
  }
  final PaperDocument next;
  try {
    next = base.withItems(items);
  } on DocumentFormatException {
    return null;
  }
  _checked[next] = _Checked(
    limits,
    bytes,
    Set.of(info.ids)
      ..removeAll(removedIds)
      ..addAll(ctx.ids.keys),
    info.grouped,
    Map.of(info.top)
      ..removeWhere((id, _) => removedIds.contains(id))
      ..addAll(cells),
  );
  debugIncrementalChecks++;
  return EditDecision._lazy(next, op);
}
