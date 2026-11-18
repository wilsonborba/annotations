part of 'editor_rules.dart';

// Erasing (B2.6, B6.6, closure topic 5 accepted). The eraser is a circle; one
// pointer move sweeps it from the previous position to the new one.
//
// Normal eraser: only free ink (strokes and shapes that are not in a group).
// Text, cards, images and grouped ink are never touched. Whole-stroke mode
// removes every touched item. Partial mode cuts touched strokes: the pieces
// outside the eraser stay as new strokes with new ids, at the same place in
// the item order, with the same tool, brush version, width, color, opacity,
// tip angle and the raw samples (position, time, pressure, tilt) of their own
// part. A touched shape becomes editable paths in partial mode (manager
// resolution of the open B6.6 case under owner rule 2): the parts of its
// outline outside the eraser stay as open paths with new ids and the same
// color, line width and opacity; the fill goes, because an open outline has
// no inside. Whole-stroke mode removes a touched shape.
//
// Dangerous mode: removes whole objects (text, cards, images, groups with all
// their members, strokes and shapes). At each eraser position it takes only the
// top object there, judged by what was visible when the gesture started, so an
// object revealed during the same gesture is never removed.

/// The normal eraser modes.
enum EraserMode { wholeStroke, partialStroke }

extension InkErasing on EditorRules {
  /// One normal eraser move from [from] to [to] (page units) with eraser
  /// [radius]. Untouched documents give an accepted decision without change.
  EditDecision erase(
    NoteDocument document, {
    required InkVec from,
    required InkVec to,
    required double radius,
    required EraserMode mode,
    required String Function() newId,
    InkSettings settings = const InkSettings(),
  }) => _run(document, (layout) {
    final next = <JsonObject>[];
    var first = -1;
    for (var i = 0; i < layout.items.length; i++) {
      final it = layout.items[i];
      List<JsonObject>? replaced;
      if (!layout.grouped[i] && _role(it) == _Role.ink) {
        if (it['kind'] == 'stroke' && mode == EraserMode.partialStroke) {
          replaced = _cutStroke(it, from, to, radius, newId, settings);
        } else if (mode == EraserMode.partialStroke) {
          replaced = _cutShape(it, from, to, radius, newId, settings);
        } else if (_touches(it, from, to, radius, settings)) {
          replaced = const [];
        }
      }
      if (replaced != null && first < 0) first = i;
      next.addAll(replaced ?? [it]);
    }
    if (first < 0) return null;
    // Keep the item order: the items from the first change on are removed and
    // added again, the pieces in the place of their stroke.
    return _batch([
      for (final it in layout.items.skip(first))
        {'op': 'delete', 'id': it['id']},
      for (final it in next.skip(first)) {'op': 'add', 'item': it},
    ]);
  });

  /// One dangerous eraser move. [start] is the document when the gesture
  /// started; targets are chosen in it and removed from [document].
  EditDecision eraseObjects(
    NoteDocument document, {
    required NoteDocument start,
    required InkVec from,
    required InkVec to,
    required double radius,
    InkSettings settings = const InkSettings(),
  }) => _run(document, (layout) {
    final targets = _topTargets(start, from, to, radius, settings);
    final remove = <int>{};
    for (final id in targets) {
      final i = layout.index[id];
      if (i != null) remove.addAll(layout.withDescendants(i));
    }
    if (remove.isEmpty) return null;
    return _batch([
      for (final i in remove.toList()..sort())
        {'op': 'delete', 'id': layout.items[i]['id']},
    ]);
  });
}

/// Ids of the top-level objects (outermost groups or free items) that are
/// on top at the eraser positions from [from] to [to] in [start].
List<String> _topTargets(
  NoteDocument start,
  InkVec from,
  InkVec to,
  double radius,
  InkSettings settings,
) {
  if (start is! PaperDocument) return const [];
  final layout = _Layout(start.toJson()['items'] as List<Object?>);
  final parent = <int, int>{};
  for (final MapEntry(key: g, value: members) in layout.members.entries) {
    for (final m in members) {
      parent[m] = g;
    }
  }
  int unit(int i) {
    var u = i;
    for (
      var depth = 0;
      parent[u] != null && depth <= layout.items.length;
      depth++
    ) {
      u = parent[u]!;
    }
    return u;
  }

  final steps = math.max(1, (from.distanceTo(to) / (radius / 2)).ceil());
  final out = <String>[];
  for (var k = 0; k <= steps; k++) {
    final p = InkVec.lerp(from, to, k / steps);
    for (var i = layout.items.length - 1; i >= 0; i--) {
      final it = layout.items[i];
      if (_role(it) == _Role.group || !_touches(it, p, p, radius, settings)) {
        continue;
      }
      final id = layout.items[unit(i)]['id'] as String;
      if (!out.contains(id)) out.add(id);
      break;
    }
  }
  return out;
}

/// Whether the eraser swept from [a] to [b] touches the visible item [it].
bool _touches(
  JsonObject it,
  InkVec a,
  InkVec b,
  double radius,
  InkSettings settings,
) {
  switch (it['kind']) {
    case 'stroke':
      final nodes = _nodesOf(it);
      if (nodes.isEmpty) return false;
      final reach = radius + _halfWidth(it);
      final path = flatten(
        segmentsOf(nodes),
        settings.flattenTolerance,
        single: nodes.first.point,
      );
      if (path.length == 1) {
        return distanceToSegment(path.first.point, a, b) <= reach;
      }
      for (var k = 1; k < path.length; k++) {
        if (segmentDistance(path[k - 1].point, path[k].point, a, b) <= reach) {
          return true;
        }
      }
      return false;
    case 'shape':
      final shape = DocumentItem.fromJson(it, family: DocumentFamily.original);
      if (shape is! ShapeItem) return false;
      final line = shapePolyline(shape, settings);
      if (line == null) return false;
      final (points, closed) = line;
      final reach = radius + shape.lineWidth / 2;
      final ring = closed ? [...points, points.first] : points;
      for (var k = 1; k < ring.length; k++) {
        if (segmentDistance(ring[k - 1], ring[k], a, b) <= reach) return true;
      }
      if (ring.length == 1 && distanceToSegment(ring.first, a, b) <= reach) {
        return true;
      }
      return shape.fill != null &&
          points.length > 2 &&
          (insidePolygon(a, points) || insidePolygon(b, points));
    default:
      final r = _blockRect(it);
      if (r == null) return false;
      return rectDistance(
            a,
            b,
            r.left.toDouble(),
            r.top.toDouble(),
            r.right.toDouble(),
            r.bottom.toDouble(),
          ) <=
          radius;
  }
}

List<InkNode> _nodesOf(JsonObject stroke) => [
  for (final n in stroke['nodes'] as List) InkNode.fromJson(n as JsonObject),
];

/// Half of the widest mark of a stroke, in page units.
double _halfWidth(JsonObject stroke) {
  final brush = Brushes.of(stroke['tool'], stroke['brush_version']);
  final pressure = (stroke['samples'] as Map)['pressure'] != null;
  final scale = brush != null && pressure ? brush.maxWidthScale : 1.0;
  return (stroke['width'] as num) / 2 * scale;
}

/// The pieces of [stroke] outside the swept eraser, or null when the eraser
/// does not touch it. An empty list removes the stroke.
List<JsonObject>? _cutStroke(
  JsonObject stroke,
  InkVec a,
  InkVec b,
  double radius,
  String Function() newId,
  InkSettings settings,
) {
  final nodes = _nodesOf(stroke);
  if (nodes.isEmpty) return null;
  final segments = segmentsOf(nodes);
  final reach = radius + _halfWidth(stroke);
  if (segments.isEmpty) {
    return distanceToSegment(nodes.first.point, a, b) <= reach
        ? const []
        : null;
  }
  final path = flatten(segments, settings.flattenTolerance);
  final erased = <(double, double)>[];
  for (var k = 1; k < path.length; k++) {
    final p = path[k - 1], q = path[k];
    if (segmentDistance(p.point, q.point, a, b) > reach) continue;
    final (s0, s1) = _insideSpan(p.point, q.point, a, b, reach);
    erased.add((p.u + (q.u - p.u) * s0, p.u + (q.u - p.u) * s1));
  }
  if (erased.isEmpty) return null;
  // The parts of the path between the erased spans stay.
  final kept = <(double, double)>[];
  var cursor = 0.0;
  for (final (s, e) in erased) {
    if (s > cursor) kept.add((cursor, s));
    cursor = math.max(cursor, e);
  }
  final end = segments.length.toDouble();
  if (cursor < end) kept.add((cursor, end));
  final out = <JsonObject>[];
  for (final (u0, u1) in kept) {
    final piece = _piece(segments, u0, u1);
    final length = flatten(piece, settings.flattenTolerance)
        .fold<(InkVec?, double)>(
          (null, 0),
          (acc, p) => (
            p.point,
            acc.$2 + (acc.$1 == null ? 0 : acc.$1!.distanceTo(p.point)),
          ),
        )
        .$2;
    if (length < settings.minFragmentLength) continue;
    out.add(_fragment(stroke, nodes, piece, u0, u1, newId()));
  }
  return out;
}

/// Partial erasing of a shape: the parts of its outline outside the eraser as
/// open path shapes, [] when nothing stays, null when it is not touched.
List<JsonObject>? _cutShape(
  JsonObject it,
  InkVec a,
  InkVec b,
  double radius,
  String Function() newId,
  InkSettings settings,
) {
  if (!_touches(it, a, b, radius, settings)) return null;
  final shape = DocumentItem.fromJson(it, family: DocumentFamily.original);
  if (shape is! ShapeItem) return const [];
  final closed = shape is! PathShape || it['closed'] == true;
  final nodes = _geometricNodes(shape) ?? _nodesOf(it);
  final segments = segmentsOf(nodes, closed: closed);
  if (segments.isEmpty) return const [];
  final reach = radius + shape.lineWidth / 2;
  final path = flatten(segments, settings.flattenTolerance);
  final erased = <(double, double)>[];
  for (var k = 1; k < path.length; k++) {
    final p = path[k - 1], q = path[k];
    if (segmentDistance(p.point, q.point, a, b) > reach) continue;
    final (s0, s1) = _insideSpan(p.point, q.point, a, b, reach);
    erased.add((p.u + (q.u - p.u) * s0, p.u + (q.u - p.u) * s1));
  }
  if (erased.isEmpty) return null;
  final end = segments.length.toDouble();
  final kept = <(double, double)>[];
  var cursor = 0.0;
  for (final (s, e) in erased) {
    if (s > cursor) kept.add((cursor, s));
    cursor = math.max(cursor, e);
  }
  if (cursor < end) kept.add((cursor, end));
  final pieces = [for (final (u0, u1) in kept) _piece(segments, u0, u1)];
  // A closed outline continues through its start: the last and the first
  // part are one piece.
  if (closed && kept.length > 1 && kept.first.$1 == 0 && kept.last.$2 == end) {
    pieces.first = [...pieces.removeLast(), ...pieces.first];
  }
  final style = {
    for (final key in const ['color', 'line_width', 'opacity']) key: it[key],
  };
  return [
    for (final piece in pieces)
      if (_length(piece, settings) >= settings.minFragmentLength)
        {
          'id': newId(),
          'kind': 'shape',
          'shape': 'path',
          ...style,
          'closed': false,
          'nodes': [for (final n in _pieceNodes(piece)) n.toJson()],
        },
  ];
}

double _length(List<CubicSegment> piece, InkSettings settings) {
  final points = flatten(piece, settings.flattenTolerance);
  var total = 0.0;
  for (var k = 1; k < points.length; k++) {
    total += points[k - 1].point.distanceTo(points[k].point);
  }
  return total;
}

/// The nodes of an open path through the cubic pieces: a straight side has
/// no handles; a node without a handle is a corner.
List<InkNode> _pieceNodes(List<CubicSegment> piece) {
  InkVec? handle(InkVec h, InkVec p) => h == p ? null : h;
  return [
    for (var k = 0; k <= piece.length; k++)
      () {
        final p = k < piece.length ? piece[k].p0 : piece.last.p3;
        final incoming = k > 0 ? handle(piece[k - 1].p2, p) : null;
        final outgoing = k < piece.length ? handle(piece[k].p1, p) : null;
        return InkNode.at(
          p,
          incoming: incoming,
          outgoing: outgoing,
          mode: NodeMode.independent,
          corner: incoming == null || outgoing == null,
        );
      }(),
  ];
}

/// The part of the straight piece [p]-[q] (as fractions 0 to 1) within
/// [reach] of the segment [a]-[b]. The distance along a straight piece is a
/// convex function, so the part is one interval around its minimum.
(double, double) _insideSpan(
  InkVec p,
  InkVec q,
  InkVec a,
  InkVec b,
  double reach,
) {
  double f(double s) => distanceToSegment(InkVec.lerp(p, q, s), a, b);
  var lo = 0.0, hi = 1.0;
  for (var k = 0; k < 60; k++) {
    final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
    if (f(m1) <= f(m2)) {
      hi = m2;
    } else {
      lo = m1;
    }
  }
  final best = (lo + hi) / 2;
  double edge(double outside, double inside) {
    if (f(outside) <= reach) return outside;
    for (var k = 0; k < 50; k++) {
      final m = (outside + inside) / 2;
      if (f(m) <= reach) {
        inside = m;
      } else {
        outside = m;
      }
    }
    return inside;
  }

  return (edge(0, best), edge(1, best));
}

/// The cubic pieces of the path from position [u0] to [u1].
List<CubicSegment> _piece(List<CubicSegment> segments, double u0, double u1) {
  final i0 = math.min(u0.floor(), segments.length - 1);
  final i1 = math.max(i0, math.min(u1.ceil() - 1, segments.length - 1));
  final t0 = u0 - i0, t1 = u1 - i1;
  if (i0 == i1) return [segments[i0].sub(t0, t1)];
  return [
    segments[i0].sub(t0, 1),
    for (var i = i0 + 1; i < i1; i++) segments[i],
    segments[i1].sub(0, t1),
  ];
}

/// A new stroke for the path part [u0]-[u1]: the original fields with a new
/// id, the raw samples of this part and its nodes.
JsonObject _fragment(
  JsonObject stroke,
  List<InkNode> nodes,
  List<CubicSegment> piece,
  double u0,
  double u1,
  String id,
) {
  final samples = stroke['samples'] as JsonObject;
  final count = (samples['x'] as List).length;
  final position = sampleMap(nodes, count);
  final (s0, s1) = (position(u0), position(u1));
  // Raw samples inside the part, with interpolated samples at the cuts.
  final at = <double>[s0];
  for (var k = s0.floor() + 1; k < s1; k++) {
    if (k > s0) at.add(k.toDouble());
  }
  if (s1 > at.last) at.add(s1);
  List<int> column(String key) {
    final values = (samples[key] as List).cast<int>();
    return [for (final p in at) columnAt(values, p).round()];
  }

  final time = column('t');
  final columns = <String, Object?>{
    for (final key in samples.keys)
      key: switch (key) {
        't' => [for (final v in time) v - time.first],
        'x' ||
        'y' ||
        'pressure' ||
        'tilt' when samples[key] != null => column(key),
        _ => samples[key],
      },
  };
  final linked = nodes.any((n) => n.sample != null);
  int? link(double p) {
    if (!linked) return null;
    final i = at.indexWhere((v) => (v - p).abs() < 1e-9);
    return i < 0 ? null : i;
  }

  InkVec? handle(InkVec? original, InkVec value, InkVec node) =>
      original == null && value == node ? null : value;
  final i0 = math.min(u0.floor(), nodes.length - 2);
  final out = <InkNode>[];
  for (var k = 0; k <= piece.length; k++) {
    final first = k == 0, last = k == piece.length;
    if (first || last) {
      // A cut makes a new end node; an end that is an original node keeps it.
      final p = first ? piece.first.p0 : piece.last.p3;
      final u = first ? u0 : u1;
      final keep = u == u.roundToDouble() ? nodes[u.round()] : null;
      final h = first ? piece.first.p1 : piece.last.p2;
      final end = (keep ?? InkNode.at(p)).copyWith(
        point: p,
        incoming: () => first ? null : handle(keep?.inPoint, h, p),
        outgoing: () => last ? null : handle(keep?.outPoint, h, p),
        sample: () => linked
            ? (link(first ? s0 : s1) ?? (first ? 0 : at.length - 1))
            : null,
      );
      out.add(end);
      continue;
    }
    final n = nodes[i0 + k];
    out.add(
      n.copyWith(
        incoming: () => handle(n.inPoint, piece[k - 1].p2, n.point),
        outgoing: () => handle(n.outPoint, piece[k].p1, n.point),
        sample: () => link(position((i0 + k).toDouble())),
      ),
    );
  }
  return {
    ...stroke,
    'id': id,
    'samples': columns,
    'nodes': [for (final n in out) n.toJson()],
  };
}
