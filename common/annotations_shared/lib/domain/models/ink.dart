/// Ink values: the four tools, their versioned brush definitions, page-unit
/// vectors and editable curve nodes in their stored integer form.
///
/// Stored ink uses integer 1/100 page units for samples, nodes and handles
/// (compact stroke encoding). Geometry works in page units with doubles and
/// returns to integers only when a value is stored.
library;

import 'dart:math' as math;

/// The four drawing tools (B6.1). The stored `tool` value is [name].
enum InkTool {
  round,
  flat,
  brush,
  highlighter;

  static InkTool? parse(Object? value) {
    for (final tool in values) {
      if (tool.name == value) return tool;
    }
    return null;
  }
}

/// How one brush version turns a stroke into a mark. A stored stroke keeps its
/// `brush_version`; it is always drawn with that definition. A definition that
/// was released never changes: a new appearance is a new version, and only an
/// explicit "apply this pen" on a stroke moves it to the new version.
final class BrushDefinition {
  const BrushDefinition._(
    this.tool,
    this.version, {
    this.pressureScale,
    this.nibThickness = 0,
  });

  final InkTool tool;
  final int version;

  /// Width factors at pressure 0 and pressure 1, linear between them, for a
  /// brush that uses real device pressure. Null: the width never changes.
  /// There is no pressure from speed: without a pressure column the factor
  /// is always 1, the selected fixed width.
  final (double, double)? pressureScale;

  /// Flat pen only: the thickness of the nib as a part of its length.
  final double nibThickness;

  bool get usesPressure => pressureScale != null;

  /// The width factor at [pressure] (0 to 1, or null without device data).
  double widthScale(double? pressure) {
    final scale = pressureScale;
    if (scale == null || pressure == null) return 1;
    final p = pressure.clamp(0.0, 1.0);
    return scale.$1 + (scale.$2 - scale.$1) * p;
  }

  /// The largest width factor of this brush.
  double get maxWidthScale => pressureScale == null
      ? 1
      : math.max(pressureScale!.$1, pressureScale!.$2);
}

/// The released brush definitions.
abstract final class Brushes {
  /// Version 1 of the four tools.
  /// - round: round tip, the same width everywhere;
  /// - flat: a nib of the selected width at the stroke tip angle, one fifth as
  ///   thick as it is long, so marks are broad or narrow by direction;
  /// - brush: width from real pressure, 0.4 times the width at no pressure to
  ///   1.6 times at full pressure (half pressure is the selected width);
  /// - highlighter: round tip, the same width, drawn as one shape per stroke.
  static const _released = [
    BrushDefinition._(InkTool.round, 1),
    BrushDefinition._(InkTool.flat, 1, nibThickness: 0.2),
    BrushDefinition._(InkTool.brush, 1, pressureScale: (0.4, 1.6)),
    BrushDefinition._(InkTool.highlighter, 1),
  ];

  /// The version that new strokes and an explicit pen change use.
  static int current(InkTool tool) => _released
      .where((d) => d.tool == tool)
      .map((d) => d.version)
      .reduce(math.max);

  /// The definition of a stored stroke. Null for a tool or version that this
  /// app does not know (a newer app made it): such a stroke is kept unchanged
  /// and is not drawn with another definition.
  static BrushDefinition? of(Object? tool, Object? version) {
    final t = InkTool.parse(tool);
    for (final d in _released) {
      if (d.tool == t && d.version == version) return d;
    }
    return null;
  }
}

/// The settings of a tool for new strokes (B6.2). Changing them never changes
/// a stored stroke.
final class BrushSettings {
  const BrushSettings({
    required this.tool,
    required this.width,
    required this.color,
    this.opacity = 1,
    this.tipAngle,
  });

  final InkTool tool;

  /// Logical page units.
  final num width;

  /// #RRGGBBAA.
  final String color;

  /// Above 0, at most 1.
  final num opacity;

  /// Flat pen: the nib angle in radians, from -pi to pi.
  final num? tipAngle;
}

/// A point or direction in logical page units.
final class InkVec {
  const InkVec(this.x, this.y);

  /// A stored point in integer 1/100 page units.
  InkVec.hundredths(int x, int y) : x = x / 100, y = y / 100;

  final double x, y;

  InkVec operator +(InkVec o) => InkVec(x + o.x, y + o.y);
  InkVec operator -(InkVec o) => InkVec(x - o.x, y - o.y);
  InkVec operator *(double s) => InkVec(x * s, y * s);
  InkVec operator -() => InkVec(-x, -y);
  double dot(InkVec o) => x * o.x + y * o.y;
  double cross(InkVec o) => x * o.y - y * o.x;
  double get length => math.sqrt(x * x + y * y);
  double distanceTo(InkVec o) => (this - o).length;
  InkVec normalized() {
    final l = length;
    return l == 0 ? const InkVec(0, 0) : InkVec(x / l, y / l);
  }

  static InkVec lerp(InkVec a, InkVec b, double t) => a + (b - a) * t;

  /// The stored integer 1/100 page units.
  int get hx => (x * 100).round();
  int get hy => (y * 100).round();

  @override
  bool operator ==(Object other) =>
      other is InkVec && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'InkVec($x, $y)';
}

/// The handle choices of a node (B6.3).
enum NodeMode {
  /// Each handle moves alone.
  independent,

  /// Both handles keep one direction; their lengths may differ.
  smooth,

  /// Both handles keep one direction and the same length.
  symmetric;

  static NodeMode? parse(Object? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// One editable node of a stroke or a path shape, in its stored form: integer
/// 1/100 page units for the node and its handles. Unknown fields and a newer
/// mode name are kept as they are.
final class InkNode {
  const InkNode({
    required this.x,
    required this.y,
    this.incoming,
    this.outgoing,
    this.modeName = 'smooth',
    this.corner = false,
    this.sample,
    this.extra = const {},
  });

  factory InkNode.at(
    InkVec point, {
    InkVec? incoming,
    InkVec? outgoing,
    NodeMode mode = NodeMode.smooth,
    bool corner = false,
    int? sample,
  }) => InkNode(
    x: point.hx,
    y: point.hy,
    incoming: incoming == null ? null : (incoming.hx, incoming.hy),
    outgoing: outgoing == null ? null : (outgoing.hx, outgoing.hy),
    modeName: mode.name,
    corner: corner,
    sample: sample,
  );

  /// Reads a stored node. The values must already be valid (the document
  /// model checked them).
  factory InkNode.fromJson(Map<String, Object?> json) {
    (int, int)? handle(Object? h) =>
        h is Map ? (h['x'] as int, h['y'] as int) : null;
    const known = ['x', 'y', 'in', 'out', 'mode', 'corner', 'sample'];
    return InkNode(
      x: json['x'] as int,
      y: json['y'] as int,
      incoming: handle(json['in']),
      outgoing: handle(json['out']),
      modeName: json['mode'] as String,
      corner: json['corner'] as bool,
      sample: json['sample'] as int?,
      extra: {
        for (final e in json.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// Integer 1/100 page units.
  final int x, y;
  final (int, int)? incoming, outgoing;
  final String modeName;
  final bool corner;

  /// The index of the raw sample that this node was fitted at (strokes only).
  final int? sample;
  final Map<String, Object?> extra;

  NodeMode? get mode => NodeMode.parse(modeName);
  InkVec get point => InkVec.hundredths(x, y);
  InkVec? get inPoint =>
      incoming == null ? null : InkVec.hundredths(incoming!.$1, incoming!.$2);
  InkVec? get outPoint =>
      outgoing == null ? null : InkVec.hundredths(outgoing!.$1, outgoing!.$2);

  InkNode copyWith({
    InkVec? point,
    InkVec? Function()? incoming,
    InkVec? Function()? outgoing,
    NodeMode? mode,
    bool? corner,
    int? Function()? sample,
  }) {
    (int, int)? h(InkVec? v) => v == null ? null : (v.hx, v.hy);
    return InkNode(
      x: point?.hx ?? x,
      y: point?.hy ?? y,
      incoming: incoming == null ? this.incoming : h(incoming()),
      outgoing: outgoing == null ? this.outgoing : h(outgoing()),
      modeName: mode?.name ?? modeName,
      corner: corner ?? this.corner,
      sample: sample == null ? this.sample : sample(),
      extra: extra,
    );
  }

  /// The stored JSON, with the key order of the shared fixtures.
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    if (incoming != null) 'in': {'x': incoming!.$1, 'y': incoming!.$2},
    if (outgoing != null) 'out': {'x': outgoing!.$1, 'y': outgoing!.$2},
    'mode': modeName,
    'corner': corner,
    if (sample != null) 'sample': sample,
    ...extra,
  };
}
