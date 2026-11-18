part of 'editor_rules.dart';

// Ink edits (B6, B10): new strokes from captured samples, geometric shapes,
// Edit as path, point editing, pen settings and brush changes. Each builder
// returns a candidate operation that [EditorRules.check] decides, like the
// other gesture builders. Raw samples are never rewritten by a point edit:
// point edits change only the nodes.

/// Collects the raw samples of one stroke from pointer input.
///
/// Values come in the units of the documents: positions in page units, time in
/// milliseconds, pressure from 0 to 1 and tilt in radians, or null when the
/// device does not report them. Nothing is synthesized: without real pressure
/// the stroke has no pressure column and the brush uses the fixed width.
final class StrokeCapture {
  StrokeCapture(
    this.brush, {
    required num pageWidth,
    this.limits = const NoteLimits(),
  }) : _pageWidth = pageWidth;

  final BrushSettings brush;
  final NoteLimits limits;
  final num _pageWidth;
  final _x = <int>[], _y = <int>[], _t = <int>[];
  final _pressure = <int?>[], _tilt = <int?>[];
  int? _start;

  int get length => _x.length;
  bool get isFull => _x.length >= limits.maxSamplesPerStroke;

  /// Adds one sample. A point outside the page stays at the page edge, the
  /// way the page clips it. Returns false when the stroke is full: the caller
  /// ends it and starts a new stroke.
  bool add(double x, double y, int timeMs, {double? pressure, double? tilt}) {
    if (isFull) return false;
    _start ??= timeMs;
    final t = timeMs - _start!;
    _x.add((x.clamp(0, _pageWidth.toDouble()) * 100).round());
    _y.add((math.max(0, y) * 100).round());
    _t.add(_t.isEmpty ? 0 : math.max(_t.last, t));
    _pressure.add(
      pressure == null ? null : (pressure.clamp(0.0, 1.0) * 1000).round(),
    );
    _tilt.add(tilt == null ? null : (tilt * 1000).round().clamp(0, _tiltMax));
    return true;
  }

  /// The stored stroke item with editable nodes fitted to the samples, or
  /// null without samples. Pressure and tilt columns exist only when every
  /// sample has them.
  JsonObject? toItem(String id, {InkSettings settings = const InkSettings()}) {
    if (_x.isEmpty) return null;
    final nodes = fitNodes(
      [for (var i = 0; i < _x.length; i++) InkVec.hundredths(_x[i], _y[i])],
      settings: settings,
      maxNodes: limits.maxNodesPerStroke,
    );
    return _item(id, nodes);
  }

  /// The stroke while it is drawn: every sample is a corner node, so the
  /// live mark costs no fitting. It is only drawn, never stored; the end of
  /// the stroke stores [toItem].
  JsonObject? toPreviewItem() {
    if (_x.isEmpty) return null;
    return _item('preview', [
      for (var i = 0; i < _x.length; i++)
        InkNode(
          x: _x[i],
          y: _y[i],
          modeName: NodeMode.independent.name,
          corner: true,
          sample: i,
        ),
    ]);
  }

  JsonObject _item(String id, List<InkNode> nodes) {
    return {
      'id': id,
      'kind': 'stroke',
      'tool': brush.tool.name,
      'brush_version': Brushes.current(brush.tool),
      'width': brush.width,
      'color': brush.color,
      'opacity': brush.opacity,
      if (brush.tool == InkTool.flat) 'tip_angle': brush.tipAngle ?? 0,
      'samples': {
        'x': [..._x],
        'y': [..._y],
        't': [..._t],
        if (!_pressure.contains(null)) 'pressure': [..._pressure.cast<int>()],
        if (!_tilt.contains(null)) 'tilt': [..._tilt.cast<int>()],
      },
      'nodes': [for (final n in nodes) n.toJson()],
    };
  }
}

/// The line style of a geometric shape.
final class ShapeStyle {
  const ShapeStyle({
    required this.color,
    required this.lineWidth,
    this.opacity = 1,
    this.fill,
  });

  /// #RRGGBBAA.
  final String color;
  final String? fill;

  /// Logical page units.
  final num lineWidth;
  final num opacity;

  JsonObject _json() => {
    'color': color,
    'line_width': lineWidth,
    'opacity': opacity,
    if (fill != null) 'fill': fill,
  };
}

/// Geometric shapes (B6.4). They stay circles, rectangles and triangles, and
/// the ordinary resize and move gestures keep them geometric, until
/// [InkEditing.editAsPath] converts one into a path.
abstract final class InkShapes {
  /// Center and radius in page units.
  static JsonObject circle(
    String id,
    InkVec center,
    num radius,
    ShapeStyle s,
  ) => {
    'id': id,
    'kind': 'shape',
    'shape': 'circle',
    ...s._json(),
    'center': {'x': _round(center.x), 'y': _round(center.y)},
    'radius': _round(radius),
  };

  /// Position and size in page units.
  static JsonObject rectangle(
    String id,
    InkVec topLeft,
    num width,
    num height,
    ShapeStyle s,
  ) => {
    'id': id,
    'kind': 'shape',
    'shape': 'rectangle',
    ...s._json(),
    'x': _round(topLeft.x),
    'y': _round(topLeft.y),
    'width': _round(width),
    'height': _round(height),
  };

  /// Three corners in page units.
  static JsonObject triangle(String id, List<InkVec> points, ShapeStyle s) => {
    'id': id,
    'kind': 'shape',
    'shape': 'triangle',
    ...s._json(),
    'points': [
      for (final p in points) {'x': _round(p.x), 'y': _round(p.y)},
    ],
  };
}

/// The end of a node that a handle drag moves.
enum NodeHandle { incoming, outgoing }

/// The circle as four symmetric nodes: the handle length that makes a cubic
/// closest to a quarter circle.
const _kappa = 0.5522847498307936;

/// Ink edits as candidate operations, used like [EditorRules.move]: preview a
/// drag with the builder and commit one accepted decision on release (one
/// Notes history step).
extension InkEditing on EditorRules {
  /// Adds a new stroke or shape item (for example [StrokeCapture.toItem]).
  EditDecision addInk(NoteDocument document, JsonObject item) =>
      _run(document, (layout) => {'op': 'add', 'item': _jsonCopy(item)});

  /// Converts a circle, rectangle or triangle into a closed path with the same
  /// look, keeping its id and style. Other items are rejected.
  EditDecision editAsPath(NoteDocument document, String id) => _run(document, (
    layout,
  ) {
    final (i, it) = _ink(layout, id);
    if (it['kind'] != 'shape' || it['shape'] == 'path') {
      throw _editorError('not_editable', i, id);
    }
    final shape = DocumentItem.fromJson(it, family: DocumentFamily.original);
    final nodes = shape is ShapeItem && shape is! PathShape
        ? _geometricNodes(shape)
        : null;
    if (nodes == null) throw _editorError('not_editable', i, id);
    const geometric = [
      'center',
      'radius',
      'x',
      'y',
      'width',
      'height',
      'points',
    ];
    return {
      'op': 'replace',
      'item': {
        for (final e in it.entries)
          if (!geometric.contains(e.key)) e.key: e.value,
        'shape': 'path',
        'closed': true,
        'nodes': [for (final n in nodes) n.toJson()],
      },
    };
  });

  /// Moves node [index] of a stroke or path by [dx], [dy] page units with
  /// both of its handles.
  EditDecision moveNode(
    NoteDocument document,
    String id,
    int index,
    num dx,
    num dy,
  ) => _nodeEdit(document, id, index, (nodes, closed) {
    final d = InkVec(_quantize(dx).toDouble(), _quantize(dy).toDouble());
    final n = nodes[index];
    nodes[index] = n.copyWith(
      point: n.point + d,
      incoming: () => n.inPoint == null ? null : n.inPoint! + d,
      outgoing: () => n.outPoint == null ? null : n.outPoint! + d,
    );
  });

  /// Moves one handle of node [index] to [to] (page units). A smooth node
  /// turns its other handle to the opposite direction and keeps its length; a
  /// symmetric node mirrors it; an independent node moves only this handle.
  EditDecision moveHandle(
    NoteDocument document,
    String id,
    int index,
    NodeHandle handle,
    InkVec to,
  ) => _nodeEdit(document, id, index, (nodes, closed) {
    final n = nodes[index];
    final other = handle == NodeHandle.incoming ? n.outPoint : n.inPoint;
    InkVec? mirrored = other;
    if (other != null) {
      final away = n.point - to;
      mirrored = switch (n.mode) {
        NodeMode.symmetric => n.point + away,
        NodeMode.smooth when away.length > 0 =>
          n.point + away.normalized() * other.distanceTo(n.point),
        _ => other,
      };
    }
    nodes[index] = handle == NodeHandle.incoming
        ? n.copyWith(incoming: () => to, outgoing: () => mirrored)
        : n.copyWith(outgoing: () => to, incoming: () => mirrored);
  });

  /// Sets the handle mode of node [index] and makes the handles follow it at
  /// once: smooth aligns the incoming handle with the outgoing one, symmetric
  /// also gives it the same length. Independent changes no handle.
  EditDecision setNodeMode(
    NoteDocument document,
    String id,
    int index,
    NodeMode mode,
  ) => _nodeEdit(document, id, index, (nodes, closed) {
    final n = nodes[index];
    var incoming = n.inPoint, outgoing = n.outPoint;
    if (mode != NodeMode.independent && incoming != null && outgoing != null) {
      final out = outgoing - n.point, inn = incoming - n.point;
      final direction = out.length > 0 ? out.normalized() : -inn.normalized();
      final length = mode == NodeMode.symmetric
          ? (out.length + inn.length) / 2
          : inn.length;
      final outLength = mode == NodeMode.symmetric ? length : out.length;
      incoming = n.point - direction * length;
      outgoing = n.point + direction * outLength;
    }
    nodes[index] = n.copyWith(
      mode: mode,
      corner: mode == NodeMode.independent ? n.corner : false,
      incoming: () => incoming,
      outgoing: () => outgoing,
    );
  });

  /// Make corner: the node loses its handles and becomes a sharp point.
  EditDecision makeCorner(NoteDocument document, String id, int index) =>
      _nodeEdit(document, id, index, (nodes, closed) {
        nodes[index] = nodes[index].copyWith(
          mode: NodeMode.independent,
          corner: true,
          incoming: () => null,
          outgoing: () => null,
        );
      });

  /// Make smooth: the node gets aligned handles along the direction between
  /// its neighbors, each one third of the distance to its neighbor.
  EditDecision makeSmooth(NoteDocument document, String id, int index) =>
      _nodeEdit(document, id, index, (nodes, closed) {
        final n = nodes[index];
        final prev = index > 0
            ? nodes[index - 1].point
            : (closed ? nodes.last.point : null);
        final next = index < nodes.length - 1
            ? nodes[index + 1].point
            : (closed ? nodes.first.point : null);
        final direction = ((next ?? n.point) - (prev ?? n.point)).normalized();
        nodes[index] = n.copyWith(
          mode: NodeMode.smooth,
          corner: false,
          incoming: () => prev == null || direction.length == 0
              ? null
              : n.point - direction * (n.point.distanceTo(prev) / 3),
          outgoing: () => next == null || direction.length == 0
              ? null
              : n.point + direction * (n.point.distanceTo(next) / 3),
        );
      });

  /// Adds a node at curve parameter [t] (0 to 1) of segment [segment] (from
  /// node `segment` to the next). The curve keeps its shape. A stroke node
  /// links to the raw sample at the same place.
  EditDecision addNode(
    NoteDocument document,
    String id,
    int segment,
    double t,
  ) => _nodeEdit(document, id, segment, (nodes, closed) {
    final segments = segmentsOf(nodes, closed: closed);
    final (i, it) = (segment, t.clamp(0.0, 1.0));
    final (left, right) = segments[i].split(it);
    final j = (i + 1) % nodes.length;
    final a = nodes[i], b = nodes[j];
    int? sample;
    if (a.sample != null && b.sample != null && j > i) {
      sample = (a.sample! + (b.sample! - a.sample!) * it).round();
    }
    nodes[i] = a.copyWith(outgoing: () => left.p1);
    nodes[j] = b.copyWith(incoming: () => right.p2);
    nodes.insert(
      i + 1,
      InkNode.at(
        left.p3,
        incoming: left.p2,
        outgoing: right.p1,
        mode: NodeMode.smooth,
        sample: sample,
      ),
    );
  }, segmentIndex: true);

  /// Removes node [index] and reconnects its neighbors with one curve that
  /// follows the two removed sections as closely as possible. A stroke keeps
  /// at least two nodes and a closed path at least three.
  EditDecision removeNode(NoteDocument document, String id, int index) =>
      _nodeEdit(document, id, index, (nodes, closed) {
        if (nodes.length <= (closed ? 3 : 2)) {
          throw EditorRuleError(EditorRule.editor, 'too_few_nodes', 'nodes', [
            id,
          ]);
        }
        final last = nodes.length - 1;
        if (!closed && (index == 0 || index == last)) {
          nodes.removeAt(index);
          final end = index == 0 ? 0 : nodes.length - 1;
          nodes[end] = index == 0
              ? nodes[end].copyWith(incoming: () => null)
              : nodes[end].copyWith(outgoing: () => null);
          return;
        }
        final segments = segmentsOf(nodes, closed: closed);
        final p = (index - 1 + nodes.length) % nodes.length;
        final q = (index + 1) % nodes.length;
        final before = segments[p], after = segments[index];
        final points = <InkVec>[
          for (var k = 0; k < 16; k++) before.at(k / 16),
          for (var k = 0; k <= 16; k++) after.at(k / 16),
        ];
        var start = before.p1 - before.p0;
        if (start.length == 0) start = before.p3 - before.p0;
        var end = after.p2 - after.p3;
        if (end.length == 0) end = after.p0 - after.p3;
        final fitted = fitSegment(points, start, end);
        nodes[p] = nodes[p].copyWith(outgoing: () => fitted.p1);
        nodes[q] = nodes[q].copyWith(incoming: () => fitted.p2);
        nodes.removeAt(index);
      });

  /// Changes width, color, opacity or tip angle of the selected strokes
  /// (B6.2). The tool and its brush version stay, so the line keeps its form.
  /// Shapes take the color, opacity and [width] as their line width.
  EditDecision restyleInk(
    NoteDocument document,
    List<String> ids, {
    num? width,
    String? color,
    num? opacity,
    num? tipAngle,
  }) => _run(document, (layout) {
    final steps = <JsonObject>[];
    for (final id in ids) {
      final (i, it) = _ink(layout, id);
      final stroke = it['kind'] == 'stroke';
      steps.add(
        _update(id, {
          (stroke ? 'width' : 'line_width'): ?width,
          'color': ?color,
          'opacity': ?opacity,
          if (tipAngle != null && stroke && it['tool'] == 'flat')
            'tip_angle': tipAngle,
        }),
      );
      if (tipAngle != null && !(stroke && it['tool'] == 'flat')) {
        throw _editorError('not_editable', i, id);
      }
    }
    return _batch(steps);
  });

  /// Applies a pen to existing strokes: the explicit pen change that may
  /// reshape a line (B6.2, B10.7). The strokes take the tool, the current
  /// brush version and the settings of [brush]; samples and nodes stay.
  EditDecision applyBrush(
    NoteDocument document,
    List<String> ids,
    BrushSettings brush,
  ) => _run(document, (layout) {
    final steps = <JsonObject>[];
    for (final id in ids) {
      final (i, it) = _ink(layout, id);
      if (it['kind'] != 'stroke') throw _editorError('not_editable', i, id);
      steps.add(
        _update(id, {
          'tool': brush.tool.name,
          'brush_version': Brushes.current(brush.tool),
          'width': brush.width,
          'color': brush.color,
          'opacity': brush.opacity,
          // A null change removes the field: only the flat pen has an angle.
          'tip_angle': brush.tool == InkTool.flat
              ? (brush.tipAngle ?? 0)
              : null,
        }),
      );
    }
    return _batch(steps);
  });

  /// Runs a node edit on a copy of the nodes of stroke or path [id].
  EditDecision _nodeEdit(
    NoteDocument document,
    String id,
    int index,
    void Function(List<InkNode> nodes, bool closed) edit, {
    bool segmentIndex = false,
  }) => _run(document, (layout) {
    final (i, it) = _ink(layout, id);
    final isPath = it['kind'] == 'shape' && it['shape'] == 'path';
    if (it['kind'] != 'stroke' && !isPath) {
      throw _editorError('not_editable', i, id);
    }
    final closed = isPath && it['closed'] == true;
    final nodes = [
      for (final n in it['nodes'] as List) InkNode.fromJson(n as JsonObject),
    ];
    final count = segmentIndex
        ? (closed ? nodes.length : nodes.length - 1)
        : nodes.length;
    if (index < 0 || index >= count) {
      throw _opError('missing_node', 'items[$i].nodes', [id]);
    }
    edit(nodes, closed);
    return _update(id, {
      'nodes': [for (final n in nodes) n.toJson()],
    });
  });
}

/// The index and JSON of ink item [id].
(int, JsonObject) _ink(_Layout layout, String id) {
  final i = layout.index[id];
  if (i == null) throw _opError('missing_item', 'id', [id]);
  final it = layout.items[i];
  if (it['kind'] != 'stroke' && it['kind'] != 'shape') {
    throw _editorError('not_editable', i, id);
  }
  return (i, it);
}

/// The closed outline of a circle, rectangle or triangle as path nodes with
/// the same look; null for other shapes.
List<InkNode>? _geometricNodes(ShapeItem shape) => switch (shape) {
  CircleShape(:final center, :final radius) => _circleNodes(
    InkVec(center.x.toDouble(), center.y.toDouble()),
    radius.toDouble(),
  ),
  RectangleShape(:final bounds) => _cornerNodes([
    InkVec(bounds.x.toDouble(), bounds.y.toDouble()),
    InkVec((bounds.x + bounds.width).toDouble(), bounds.y.toDouble()),
    InkVec(
      (bounds.x + bounds.width).toDouble(),
      (bounds.y + bounds.height).toDouble(),
    ),
    InkVec(bounds.x.toDouble(), (bounds.y + bounds.height).toDouble()),
  ]),
  TriangleShape(:final points) => _cornerNodes([
    for (final p in points) InkVec(p.x.toDouble(), p.y.toDouble()),
  ]),
  _ => null,
};

List<InkNode> _cornerNodes(List<InkVec> points) => [
  for (final p in points)
    InkNode.at(p, mode: NodeMode.independent, corner: true),
];

List<InkNode> _circleNodes(InkVec c, double r) {
  final k = r * _kappa;
  return [
    for (final (dx, dy) in const [
      (1.0, 0.0),
      (0.0, 1.0),
      (-1.0, 0.0),
      (0.0, -1.0),
    ])
      InkNode.at(
        c + InkVec(dx, dy) * r,
        // The tangent turns with the circle: (-dy, dx) at this point.
        incoming: c + InkVec(dx, dy) * r - InkVec(-dy, dx) * k,
        outgoing: c + InkVec(dx, dy) * r + InkVec(-dy, dx) * k,
        mode: NodeMode.symmetric,
      ),
  ];
}
