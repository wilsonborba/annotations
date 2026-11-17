part of 'editor_rules.dart';

// Builders of candidate operations for editor gestures (B2 move, B3 resize,
// type C text input, paste and duplicate). Each returns an operation in the
// fixture format; [EditorRules.check] then decides. None of them names an item
// that the gesture does not change, so neighbors never move.

const _wrappingCards = [
  'link_card',
  'website_card',
  'youtube_card',
  'file_card',
  'task_card',
  'quiz_card',
];
const _proportional = ['image', 'pdf_preview'];
const _freeArea = ['csv_table', 'reports_embed'];

/// A delta in page units at the 1/100 resolution of stored ink.
num _quantize(num v) => (v * 100).round() / 100;

/// Item indexes of [ids] in document order, with group members if asked.
List<int> _indexes(
  _Layout layout,
  List<String> ids, {
  required bool withDescendants,
}) {
  final out = <int>{};
  for (var n = 0; n < ids.length; n++) {
    final i = layout.index[ids[n]];
    if (i == null) throw _opError('missing_item', 'ids[$n]', [ids[n]]);
    out.addAll(withDescendants ? layout.withDescendants(i) : [i]);
  }
  return out.toList()..sort();
}

JsonObject _update(String id, JsonObject changes) => {
  'op': 'update',
  'id': id,
  'changes': changes,
};

JsonObject _batch(List<JsonObject> steps) => {'op': 'batch', 'steps': steps};

JsonObject _moveOperation(_Layout layout, List<String> ids, num dx, num dy) {
  final (qx, qy) = (_quantize(dx), _quantize(dy));
  (num, num) shift(num x, num y) => (x + qx, y + qy);
  return _batch([
    for (final i in _indexes(layout, ids, withDescendants: true))
      if (_role(layout.items[i]) != _Role.group)
        _update(
          layout.items[i]['id'] as String,
          _mapGeometry(layout.items[i], shift, 1),
        ),
  ]);
}

/// The corner of [r] that stays in place, and the position of the new box.
(num, num) _fixed(EditorRect r, ResizeAnchor anchor) => switch (anchor) {
  ResizeAnchor.topLeft => (r.left, r.top),
  ResizeAnchor.topRight => (r.right, r.top),
  ResizeAnchor.bottomLeft => (r.left, r.bottom),
  ResizeAnchor.bottomRight => (r.right, r.bottom),
};

EditorRuleError _editorError(String code, int index, String id) =>
    EditorRuleError(EditorRule.editor, code, 'items[$index]', [id]);

JsonObject _resizeOperation(
  _Layout layout,
  EditorSettings settings,
  String id, {
  required num width,
  required num? height,
  required ResizeAnchor anchor,
  required num? measuredHeight,
  required Map<String, num> measuredHeights,
  required FontSizeResolver? effectiveFontSize,
}) {
  final i = _indexes(layout, [id], withDescendants: false).single;
  final item = layout.items[i];
  final rect = layout.rects[i];
  final min = settings.minResizeExtent;
  final kind = item['kind'];
  if (kind == 'group' || kind == 'stroke' || kind == 'shape') {
    // Whole-object scaling from a corner (B3.1 drawing, B3.2 group).
    if (rect == null) throw _editorError('not_resizable', i, id);
    final num scale;
    if (rect.width > 0) {
      scale = width / rect.width;
    } else if (rect.height > 0 && height != null) {
      scale = height / rect.height;
    } else {
      throw _editorError('not_resizable', i, id);
    }
    if (math.max(rect.width, rect.height) * scale < min) {
      throw _editorError('below_minimum_size', i, id);
    }
    final (fx, fy) = _fixed(rect, anchor);
    (num, num) f(num x, num y) =>
        (fx + (x - fx) * scale, fy + (y - fy) * scale);
    if (kind != 'group') return _update(id, _mapGeometry(item, f, scale));
    final steps = <JsonObject>[];
    final rejected = <EditorRuleError>[];
    for (final m in layout.withDescendants(i)) {
      final member = layout.items[m];
      if (_role(member) == _Role.group) continue;
      final memberId = member['id'] as String;
      final changes = _mapGeometry(member, f, scale);
      if (member['kind'] == 'text') {
        // B3.2: whole-group resize scales text size too.
        final spans = [
          for (final s in member['spans'] as List)
            {...(s as Map).cast<String, Object?>()},
        ];
        for (final (n, s) in spans.indexed) {
          final size =
              s['size'] as num? ?? effectiveFontSize?.call(memberId, n);
          if (size == null) {
            rejected.add(_editorError('measurement_required', m, memberId));
            break;
          }
          s['size'] = _round(size * scale);
        }
        changes['spans'] = spans;
        if (measuredHeights[memberId] case final h?) changes['height'] = h;
      } else if (_wrappingCards.contains(member['kind'])) {
        // Card text keeps its size; the card wraps and the app measures it.
        final h = measuredHeights[memberId];
        if (h == null) {
          rejected.add(_editorError('measurement_required', m, memberId));
        } else {
          changes['height'] = h;
        }
      }
      steps.add(_update(memberId, changes));
    }
    final operation = _batch(steps);
    if (rejected.isNotEmpty) throw _Rejected(rejected.first, operation);
    return operation;
  }
  if (rect == null) throw _editorError('not_resizable', i, id);
  final num w = width;
  final num h;
  if (_proportional.contains(kind)) {
    h = w * rect.height / rect.width;
  } else if (_freeArea.contains(kind)) {
    h = height ?? rect.height;
  } else if (kind == 'text' || _wrappingCards.contains(kind)) {
    // Width changes, font size stays, the text wraps: the app measures it.
    if (measuredHeight == null) {
      throw _Rejected(
        _editorError('measurement_required', i, id),
        _update(id, {'width': _round(w)}),
      );
    }
    h = measuredHeight;
  } else {
    throw _opError('invalid_operation', 'operation');
  }
  if (w < min || h < min) throw _editorError('below_minimum_size', i, id);
  final (fx, fy) = _fixed(rect, anchor);
  final left = switch (anchor) {
    ResizeAnchor.topLeft || ResizeAnchor.bottomLeft => fx,
    _ => fx - w,
  };
  // Wrapping text always grows downward from its top (B3.1, type C).
  final measured = kind == 'text' || _wrappingCards.contains(kind);
  final top = switch (anchor) {
    _ when measured => rect.top,
    ResizeAnchor.topLeft || ResizeAnchor.topRight => fy,
    _ => fy - h,
  };
  return _update(id, {
    'x': _round(left),
    'y': _round(top),
    'width': _round(w),
    'height': measured ? h : _round(h),
  });
}

JsonObject _textOperation(
  _Layout layout,
  String id,
  List<Object?> spans,
  num? measuredHeight,
) {
  final i = _indexes(layout, [id], withDescendants: false).single;
  if (layout.items[i]['kind'] != 'text') {
    throw _opError('invalid_operation', 'operation');
  }
  final changes = <String, Object?>{'spans': spans};
  if (measuredHeight == null) {
    throw _Rejected(
      _editorError('measurement_required', i, id),
      _update(id, changes),
    );
  }
  changes['height'] = measuredHeight;
  return _update(id, changes);
}

JsonObject _pasteOperation(
  DocumentSchema schema,
  List<Object?> clipboard,
  num dx,
  num dy,
  String Function() newId,
) {
  final copies = _jsonCopy(clipboard) as List<Object?>;
  // The copies must be valid items before their geometry can move.
  final ctx = _Ctx(
    schema.family ?? DocumentFamily.original,
    const NoteLimits(),
  );
  const anywhere = _Area(double.maxFinite, null);
  final ids = <String, String>{};
  for (var n = 0; n < copies.length; n++) {
    try {
      ctx.paperItem(copies[n], 'items[$n]', anywhere);
    } on DocumentFormatException catch (e) {
      throw EditorRuleError(EditorRule.documentSchema, e.code, e.path);
    }
    ids[(copies[n] as Map)['id'] as String] = newId();
  }
  final (qx, qy) = (_quantize(dx), _quantize(dy));
  (num, num) shift(num x, num y) => (x + qx, y + qy);
  return _batch([
    for (final copy in copies.cast<JsonObject>())
      {
        'op': 'add',
        'item': {
          ...copy,
          'id': ids[copy['id']],
          if (copy['kind'] == 'group')
            'members': [for (final m in copy['members'] as List) ids[m] ?? m]
          else
            ..._mapGeometry(copy, shift, 1),
        },
      },
  ]);
}

/// Deletes the items [ids] with every member of their groups (B2.6: a group
/// is removed as a whole).
JsonObject _removeOperation(_Layout layout, List<String> ids) => _batch([
  for (final i in _indexes(layout, ids, withDescendants: true))
    {'op': 'delete', 'id': layout.items[i]['id']},
]);

/// Adds a group of the items [ids] (B2.5). The members keep their items and
/// positions; the group lists them in document order.
JsonObject _groupOperation(_Layout layout, List<String> ids, String id) {
  final members = _indexes(layout, ids, withDescendants: false);
  if (members.length < 2) throw _opError('invalid_operation', 'ids');
  return {
    'op': 'add',
    'item': {
      'id': id,
      'kind': 'group',
      'members': [for (final i in members) layout.items[i]['id']],
    },
  };
}

/// Removes the group items [ids]. Their members stay where they are (B2.5).
JsonObject _ungroupOperation(_Layout layout, List<String> ids) {
  final groups = _indexes(layout, ids, withDescendants: false);
  for (final i in groups) {
    if (_role(layout.items[i]) != _Role.group) {
      throw _opError('invalid_operation', 'ids', [
        layout.items[i]['id'] as String,
      ]);
    }
  }
  return _batch([
    for (final i in groups) {'op': 'delete', 'id': layout.items[i]['id']},
  ]);
}
