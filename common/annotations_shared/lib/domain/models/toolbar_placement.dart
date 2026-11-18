/// Where the editor toolbar sits (B7 rules 1, 2, 7, 8): docked at a screen
/// edge or floating. A device value, never note data, so Instant participants
/// never change one another's toolbar.
library;

/// The edges a toolbar docks at, or floating.
enum ToolbarEdge {
  top,
  bottom,
  left,
  right,
  floating;

  bool get vertical => this == left || this == right;
}

/// The toolbar placement. A floating toolbar keeps its place as a fraction
/// of the free screen area (0 to 1 on each axis), so it stays inside the
/// screen after a rotation or a window resize.
final class ToolbarPlacement {
  const ToolbarPlacement({
    this.edge = ToolbarEdge.top,
    this.x = 0.5,
    this.y = 0,
  });

  final ToolbarEdge edge;
  final double x, y;

  ToolbarPlacement docked(ToolbarEdge value) =>
      ToolbarPlacement(edge: value, x: x, y: y);

  ToolbarPlacement floating(double fx, double fy) => ToolbarPlacement(
    edge: ToolbarEdge.floating,
    x: fx.clamp(0.0, 1.0),
    y: fy.clamp(0.0, 1.0),
  );

  Map<String, Object?> toJson() => {'edge': edge.name, 'x': x, 'y': y};

  /// Reads a device value; a damaged value gives the first placement (top).
  factory ToolbarPlacement.fromJson(Object? json) {
    if (json is! Map) return const ToolbarPlacement();
    final edge = ToolbarEdge.values
        .where((e) => e.name == json['edge'])
        .firstOrNull;
    double fraction(Object? v, double fallback) =>
        v is num && v >= 0 && v <= 1 ? v.toDouble() : fallback;
    return ToolbarPlacement(
      edge: edge ?? ToolbarEdge.top,
      x: fraction(json['x'], 0.5),
      y: fraction(json['y'], 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ToolbarPlacement &&
      other.edge == edge &&
      other.x == x &&
      other.y == y;
  @override
  int get hashCode => Object.hash(edge, x, y);
}
