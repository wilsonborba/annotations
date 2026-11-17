part of 'editor_rules.dart';

/// An axis-aligned rectangle in logical page units.
final class EditorRect {
  const EditorRect(this.left, this.top, this.right, this.bottom);
  final num left, top, right, bottom;
  num get width => right - left;
  num get height => bottom - top;

  /// Positive-area intersection. Shared edges and corners are not an overlap.
  bool overlaps(EditorRect o) =>
      math.min(right, o.right) > math.max(left, o.left) &&
      math.min(bottom, o.bottom) > math.max(top, o.top);
  EditorRect union(EditorRect o) => EditorRect(
    math.min(left, o.left),
    math.min(top, o.top),
    math.max(right, o.right),
    math.max(bottom, o.bottom),
  );
  static EditorRect? ofPoints(Iterable<(num, num)> points) {
    EditorRect? result;
    for (final (x, y) in points) {
      final p = EditorRect(x, y, x, y);
      result = result == null ? p : result.union(p);
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is EditorRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;
  @override
  int get hashCode => Object.hash(left, top, right, bottom);
  @override
  String toString() => 'EditorRect($left, $top, $right, $bottom)';
}

enum _Role { block, group, ink }

_Role _role(JsonObject item) => switch (item['kind']) {
  'group' => _Role.group,
  'stroke' || 'shape' => _Role.ink,
  _ => _Role.block,
};

/// Rectangles, group members and collision units of the items of a schema-valid
/// `note-original` or `instant-room` document, computed like the backend.
final class _Layout {
  _Layout(List<Object?> raw)
    : items = [for (final it in raw) it as JsonObject] {
    for (var i = 0; i < items.length; i++) {
      if (items[i]['id'] case final String id) index[id] = i;
    }
    grouped = List.filled(items.length, false);
    for (var g = 0; g < items.length; g++) {
      if (_role(items[g]) != _Role.group) continue;
      final list = <int>[
        for (final m in (items[g]['members'] as List? ?? const []))
          if (index[m] case final int i) i,
      ]..sort();
      for (final m in list) {
        grouped[m] = true;
      }
      members[g] = list;
    }
    rects = List.filled(items.length, null);
    structured = List.filled(items.length, null);
    for (var i = 0; i < items.length; i++) {
      _rect(i, 0);
      _hasBlock(i, 0);
    }
  }

  final List<JsonObject> items;
  final index = <String, int>{};
  final members = <int, List<int>>{};
  late final List<bool> grouped;
  late final List<EditorRect?> rects;
  late final List<bool?> structured;

  EditorRect? rectOf(String id) => index[id] == null ? null : rects[index[id]!];

  /// The item and every member of its groups, at any depth, in document order.
  List<int> withDescendants(int i) {
    final out = <int>{};
    void walk(int n) {
      if (!out.add(n)) return;
      for (final m in members[n] ?? const <int>[]) {
        walk(m);
      }
    }

    walk(i);
    return out.toList()..sort();
  }

  bool _collides(int i) =>
      _role(items[i]) != _Role.ink && structured[i] == true;

  /// The first overlapping pair: the top level first, then each group.
  void check() {
    _level([
      for (var i = 0; i < items.length; i++)
        if (!grouped[i] && _collides(i)) i,
    ]);
    for (final g in members.keys.toList()..sort()) {
      _level(members[g]!.where(_collides).toList());
    }
  }

  void _level(List<int> units) {
    for (var n = 0; n < units.length; n++) {
      final a = units[n];
      final ra = rects[a];
      if (ra == null) continue;
      for (final b in units.skip(n + 1)) {
        final rb = rects[b];
        if (rb == null || !ra.overlaps(rb)) continue;
        final group =
            _role(items[a]) == _Role.group || _role(items[b]) == _Role.group;
        final code = group ? 'group_overlap' : 'block_overlap';
        throw EditorRuleError(code, code, 'items[$b]', [
          items[a]['id'] as String,
          items[b]['id'] as String,
        ]);
      }
    }
  }

  bool _hasBlock(int i, int depth) {
    if (structured[i] case final bool v) return v;
    final bool v = switch (items[i]['kind']) {
      'stroke' || 'shape' => false,
      'group' when depth <= items.length => (members[i] ?? const <int>[]).any(
        (m) => _hasBlock(m, depth + 1),
      ),
      'group' => false,
      _ => true,
    };
    return structured[i] = v;
  }

  EditorRect? _rect(int i, int depth) {
    if (rects[i] != null || depth > items.length) return rects[i];
    final it = items[i];
    final EditorRect? r = switch (it['kind']) {
      'group' =>
        (members[i] ?? const <int>[])
            .map((m) => _rect(m, depth + 1))
            .whereType<EditorRect>()
            .fold<EditorRect?>(null, (a, b) => a == null ? b : a.union(b)),
      'stroke' => EditorRect.ofPoints([
        ..._samplePoints(it['samples']),
        ..._nodePoints(it['nodes']),
      ]),
      'shape' => switch (it['shape']) {
        'circle' => _circleRect(it),
        'triangle' => EditorRect.ofPoints([
          for (final p in (it['points'] as List? ?? const []))
            ((p as Map)['x'] as num, p['y'] as num),
        ]),
        'path' => EditorRect.ofPoints(_nodePoints(it['nodes'])),
        _ => _blockRect(it),
      },
      _ => _blockRect(it),
    };
    return rects[i] = r;
  }
}

EditorRect? _blockRect(JsonObject it) {
  if (it case {
    'x': final num x,
    'y': final num y,
    'width': final num w,
    'height': final num h,
  }) {
    return EditorRect(x, y, x + w, y + h);
  }
  return null;
}

EditorRect? _circleRect(JsonObject it) {
  final c = it['center'] as Map;
  final (x, y, r) = (c['x'] as num, c['y'] as num, it['radius'] as num);
  return EditorRect.ofPoints([(x - r, y - r), (x + r, y + r)]);
}

Iterable<(num, num)> _samplePoints(Object? samples) sync* {
  final s = samples as Map;
  final xs = s['x'] as List, ys = s['y'] as List;
  for (var i = 0; i < math.min(xs.length, ys.length); i++) {
    yield ((xs[i] as int) / 100, (ys[i] as int) / 100);
  }
}

/// Nodes and their curve handles, stored in 1/100 page units.
Iterable<(num, num)> _nodePoints(Object? nodes) sync* {
  for (final n in (nodes as List? ?? const [])) {
    for (final p in [n, (n as Map)['in'], n['out']]) {
      if (p case {'x': final int x, 'y': final int y}) yield (x / 100, y / 100);
    }
  }
}

// Transformations. Every result keeps the storage form of the document:
// block geometry in page units, ink points in integer 1/100 page units.

/// A point transform in page units.
typedef _Map = (num, num) Function(num x, num y);

/// Rounds a page-unit value to 1/100, the resolution of stored ink, so that
/// repeated edits stay deterministic.
num _round(num v) {
  final r = (v * 100).round();
  return r % 100 == 0 ? r ~/ 100 : r / 100;
}

/// A copy of an ink point object `{x, y, ...}` in 1/100 units through [f].
JsonObject _mapInkPoint(Map p, _Map f) {
  final (x, y) = f((p['x'] as int) / 100, (p['y'] as int) / 100);
  return {
    ...p.cast<String, Object?>(),
    'x': (x * 100).round(),
    'y': (y * 100).round(),
  };
}

List<Object?> _mapNodes(Object? nodes, _Map f) => [
  for (final n in nodes as List)
    {
      ..._mapInkPoint(n as Map, f),
      if (n['in'] case final Map h) 'in': _mapInkPoint(h, f),
      if (n['out'] case final Map h) 'out': _mapInkPoint(h, f),
    },
];

/// The changed top-level fields of an ink item or a block mapped through [f].
/// [scale] multiplies line widths and sizes; a translation passes 1.
JsonObject _mapGeometry(JsonObject it, _Map f, num scale) {
  JsonObject point(Map p) {
    final (x, y) = f(p['x'] as num, p['y'] as num);
    return {...p.cast<String, Object?>(), 'x': _round(x), 'y': _round(y)};
  }

  switch (it['kind']) {
    case 'stroke':
      final s = it['samples'] as Map;
      final xs = s['x'] as List, ys = s['y'] as List;
      final nx = <int>[], ny = <int>[];
      for (var i = 0; i < xs.length; i++) {
        final (x, y) = f((xs[i] as int) / 100, (ys[i] as int) / 100);
        nx.add((x * 100).round());
        ny.add((y * 100).round());
      }
      return {
        'samples': {...s.cast<String, Object?>(), 'x': nx, 'y': ny},
        'nodes': _mapNodes(it['nodes'], f),
        if (scale != 1) 'width': (it['width'] as num) * scale,
      };
    case 'shape':
      final changes = <String, Object?>{
        if (scale != 1) 'line_width': (it['line_width'] as num) * scale,
      };
      switch (it['shape']) {
        case 'circle':
          changes['center'] = point(it['center'] as Map);
          if (scale != 1) {
            changes['radius'] = _round((it['radius'] as num) * scale);
          }
        case 'triangle':
          changes['points'] = [
            for (final p in it['points'] as List) point(p as Map),
          ];
        case 'path':
          changes['nodes'] = _mapNodes(it['nodes'], f);
        default:
          changes.addAll(_mapBox(it, f));
      }
      return changes;
    default:
      return _mapBox(it, f);
  }
}

/// `x`, `y`, `width` and `height` mapped through [f] by their two corners.
JsonObject _mapBox(JsonObject it, _Map f) {
  final (x, y) = (it['x'] as num, it['y'] as num);
  final (x0, y0) = f(x, y);
  final (x1, y1) = f(x + (it['width'] as num), y + (it['height'] as num));
  final (left, top) = (_round(x0), _round(y0));
  return {
    'x': left,
    'y': top,
    'width': _round(_round(x1) - left),
    'height': _round(_round(y1) - top),
  };
}
