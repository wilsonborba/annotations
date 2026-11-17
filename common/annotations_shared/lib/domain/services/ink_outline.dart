/// Brush outlines: the filled shape of a stored stroke or shape, computed the
/// same way on every platform from the stored integers.
///
/// Drawing rule for every renderer (screen, PDF, export):
/// 1. Draw one [InkOutline] as ONE filled path: all [InkOutline.pieces] with
///    the non-zero fill rule, in one paint call with [InkOutline.argb]. The
///    pieces all turn the same way, so the non-zero rule fills their union and
///    a stroke that crosses itself keeps one opacity (highlighter, B6.1).
/// 2. Draw each stroke with its own paint call, in item order. A second stroke
///    over the first one blends again, so the overlap of two highlighter
///    strokes is darker.
/// 3. Never stamp translucent pieces one by one, and never keep a picture of
///    ink instead of these outlines.
///
/// The outline comes from the editable nodes, so a node edit shows at once.
/// The raw samples give the pressure along the path through the node links.
library;

import 'dart:math' as math;

import '../../core/ink_settings.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'ink_geometry.dart';

/// The filled shape of one stroke or one shape line, in page units.
final class InkOutline {
  const InkOutline(this.pieces, this.color, this.opacity);

  /// Convex polygons that all turn the same way. Fill them together.
  final List<List<InkVec>> pieces;

  /// #RRGGBBAA and the item opacity.
  final String color;
  final num opacity;

  /// 0xAARRGGBB with the color alpha times the opacity.
  int get argb => colorArgb(color, opacity);
}

/// A geometric shape: its optional fill polygon and its line outline.
final class ShapeOutline {
  const ShapeOutline(this.fill, this.fillColor, this.line);

  /// The closed polygon of the fill, or null without a fill.
  final List<InkVec>? fill;
  final String? fillColor;
  final InkOutline line;

  int? get fillArgb =>
      fillColor == null ? null : colorArgb(fillColor!, line.opacity);
}

/// 0xAARRGGBB of a #RRGGBBAA color with its alpha multiplied by [opacity].
int colorArgb(String color, num opacity) {
  final v = int.parse(color.substring(1), radix: 16);
  final alpha = ((v & 0xFF) * opacity).round().clamp(0, 255);
  return (alpha << 24) | (v >> 8);
}

/// The outline of [stroke], or null when its tool or brush version is not
/// known to this app (a newer app wrote it). Such a stroke is never drawn
/// with another brush definition.
InkOutline? strokeOutline(
  StrokeItem stroke, {
  InkSettings settings = const InkSettings(),
}) {
  final brush = Brushes.of(stroke.tool, stroke.brushVersion);
  if (brush == null) return null;
  final nodes = [for (final n in stroke.nodes) InkNode.fromJson(n.toJson())];
  if (nodes.isEmpty) return null;
  // A pressure brush draws at least one piece per raw sample, so the width
  // follows every pressure sample even along a straight section.
  final pressure = brush.usesPressure ? stroke.samples.pressure : null;
  final sample = sampleMap(nodes, stroke.samples.x.length);
  final path = flatten(
    segmentsOf(nodes),
    settings.flattenTolerance,
    single: nodes.first.point,
    minSteps: pressure == null
        ? null
        : (i) => (sample(i + 1.0) - sample(i.toDouble())).ceil(),
  );
  final width = stroke.width.toDouble();
  final List<InkVec> Function(int) tip;
  switch (brush.tool) {
    case InkTool.flat:
      final a = (stroke.tipAngle ?? 0).toDouble();
      final along = InkVec(math.cos(a), math.sin(a)) * (width / 2);
      final across =
          InkVec(-math.sin(a), math.cos(a)) * (width * brush.nibThickness / 2);
      tip = (i) {
        final p = path[i].point;
        return [
          p - along - across,
          p + along - across,
          p + along + across,
          p - along + across,
        ];
      };
    case InkTool.round || InkTool.brush || InkTool.highlighter:
      tip = (i) {
        final p = pressure == null
            ? null
            : columnAt(pressure, sample(path[i].u)) / 1000;
        final r = width / 2 * brush.widthScale(p);
        return _disc(path[i].point, r, settings.flattenTolerance);
      };
  }
  return InkOutline(_sweep(path.length, tip), stroke.color, stroke.opacity);
}

/// The outline of a shape. Circles, rectangles and triangles stay geometric;
/// a path shape follows its nodes.
ShapeOutline? shapeOutline(
  ShapeItem shape, {
  InkSettings settings = const InkSettings(),
}) {
  final line = shapePolyline(shape, settings);
  if (line == null) return null;
  final (points, closed) = line;
  final r = shape.lineWidth / 2;
  final ring = closed && points.length > 2 ? [...points, points.first] : points;
  return ShapeOutline(
    shape.fill == null || points.length < 3 ? null : points,
    shape.fill,
    InkOutline(
      _sweep(ring.length, (i) => _disc(ring[i], r, settings.flattenTolerance)),
      shape.color,
      shape.opacity,
    ),
  );
}

/// The line of a shape as points in page units, and whether it is closed.
(List<InkVec>, bool)? shapePolyline(ShapeItem shape, InkSettings settings) {
  switch (shape) {
    case CircleShape(:final center, :final radius):
      final c = InkVec(center.x.toDouble(), center.y.toDouble());
      final r = radius.toDouble();
      final n = _discSteps(r, settings.flattenTolerance);
      return (
        [
          for (var k = 0; k < n; k++)
            c +
                InkVec(
                      math.cos(2 * math.pi * k / n),
                      math.sin(2 * math.pi * k / n),
                    ) *
                    r,
        ],
        true,
      );
    case RectangleShape(:final bounds):
      final (x, y) = (bounds.x.toDouble(), bounds.y.toDouble());
      final (w, h) = (bounds.width.toDouble(), bounds.height.toDouble());
      return (
        [
          InkVec(x, y),
          InkVec(x + w, y),
          InkVec(x + w, y + h),
          InkVec(x, y + h),
        ],
        true,
      );
    case TriangleShape(:final points):
      return (
        [for (final p in points) InkVec(p.x.toDouble(), p.y.toDouble())],
        true,
      );
    case PathShape(:final nodes, :final closed):
      final ink = [for (final n in nodes) InkNode.fromJson(n.toJson())];
      final flat = flatten(
        segmentsOf(ink, closed: closed),
        settings.flattenTolerance,
        single: ink.first.point,
      );
      final points = [for (final p in flat) p.point];
      if (closed && points.length > 1) points.removeLast();
      return (points, closed);
  }
}

/// The union of the tip shape moved along the path: one convex hull for each
/// straight piece. A single point is the tip shape itself.
List<List<InkVec>> _sweep(int count, List<InkVec> Function(int) tip) {
  if (count == 1) return [convexHull(tip(0))];
  final pieces = <List<InkVec>>[];
  var previous = tip(0);
  for (var i = 1; i < count; i++) {
    final next = tip(i);
    pieces.add(convexHull([...previous, ...next]));
    previous = next;
  }
  return pieces;
}

/// Vertices of a disc polygon: a multiple of four, so the extreme points of
/// the disc are vertices, within [tolerance] of the circle.
int _discSteps(double r, double tolerance) {
  if (r <= tolerance) return 8;
  final n = (math.pi / math.acos(1 - tolerance / r)).ceil();
  return (n.clamp(8, 96) + 3) ~/ 4 * 4;
}

List<InkVec> _disc(InkVec c, double r, double tolerance) {
  final n = _discSteps(r, tolerance);
  return [
    for (var k = 0; k < n; k++)
      c +
          InkVec(math.cos(2 * math.pi * k / n), math.sin(2 * math.pi * k / n)) *
              r,
  ];
}
