/// Curve geometry of editable ink: cubic segments between nodes, flattening,
/// distances, convex hulls and node fitting with a bounded error.
///
/// Everything here works in logical page units and is deterministic, so every
/// platform computes the same curves from the same stored integers.
library;

import 'dart:math' as math;

import '../../core/ink_settings.dart';
import '../models/ink.dart';

/// One cubic Bezier segment.
final class CubicSegment {
  const CubicSegment(this.p0, this.p1, this.p2, this.p3);
  final InkVec p0, p1, p2, p3;

  InkVec at(double t) {
    final s = 1 - t;
    return p0 * (s * s * s) +
        p1 * (3 * s * s * t) +
        p2 * (3 * s * t * t) +
        p3 * (t * t * t);
  }

  InkVec derivative(double t) {
    final s = 1 - t;
    return (p1 - p0) * (3 * s * s) +
        (p2 - p1) * (6 * s * t) +
        (p3 - p2) * (3 * t * t);
  }

  InkVec secondDerivative(double t) =>
      (p2 - p1 * 2 + p0) * (6 * (1 - t)) + (p3 - p2 * 2 + p1) * (6 * t);

  /// The two halves at [t] (de Casteljau). Together they draw the same curve.
  (CubicSegment, CubicSegment) split(double t) {
    final a = InkVec.lerp(p0, p1, t);
    final b = InkVec.lerp(p1, p2, t);
    final c = InkVec.lerp(p2, p3, t);
    final d = InkVec.lerp(a, b, t);
    final e = InkVec.lerp(b, c, t);
    final f = InkVec.lerp(d, e, t);
    return (CubicSegment(p0, a, d, f), CubicSegment(f, e, c, p3));
  }

  /// The part of the curve from [t0] to [t1].
  CubicSegment sub(double t0, double t1) {
    var seg = this;
    if (t1 < 1) seg = seg.split(t1).$1;
    if (t0 > 0) seg = seg.split(t1 == 0 ? 0 : t0 / t1).$2;
    return seg;
  }

  /// Pieces needed so that straight lines stay within [tolerance].
  int steps(double tolerance) {
    final d = math.max((p2 - p1 * 2 + p0).length, (p3 - p2 * 2 + p1).length);
    // The flattening error is at most 6 * d / (8 * n * n).
    return math.max(1, math.sqrt(0.75 * d / tolerance).ceil());
  }
}

/// The segments of a node list: node i to node i + 1, and the last node to
/// the first one for a closed path. A missing handle is the node itself.
List<CubicSegment> segmentsOf(List<InkNode> nodes, {bool closed = false}) {
  final out = <CubicSegment>[];
  final count = closed && nodes.length > 1 ? nodes.length : nodes.length - 1;
  for (var i = 0; i < count; i++) {
    final a = nodes[i], b = nodes[(i + 1) % nodes.length];
    out.add(
      CubicSegment(
        a.point,
        a.outPoint ?? a.point,
        b.inPoint ?? b.point,
        b.point,
      ),
    );
  }
  return out;
}

/// A point of a flattened path with its position `u`: the segment index plus
/// the curve parameter inside that segment.
final class PathPoint {
  const PathPoint(this.point, this.u);
  final InkVec point;
  final double u;
}

/// The path as straight pieces within [tolerance] of the curves, with at
/// least [minSteps] pieces per segment if given. A path without segments is
/// its single node.
List<PathPoint> flatten(
  List<CubicSegment> segments,
  double tolerance, {
  InkVec? single,
  int Function(int segment)? minSteps,
}) {
  if (segments.isEmpty) return [if (single != null) PathPoint(single, 0)];
  final out = <PathPoint>[PathPoint(segments.first.p0, 0)];
  for (var i = 0; i < segments.length; i++) {
    final n = math.max(segments[i].steps(tolerance), minSteps?.call(i) ?? 1);
    for (var k = 1; k <= n; k++) {
      out.add(PathPoint(segments[i].at(k / n), i + k / n));
    }
  }
  return out;
}

/// The point of [segments] at path position [u].
InkVec pointAt(List<CubicSegment> segments, double u) {
  final i = math.min(u.floor(), segments.length - 1);
  return segments[i].at(u - i);
}

double distanceToSegment(InkVec p, InkVec a, InkVec b) {
  final ab = b - a;
  final l = ab.dot(ab);
  final t = l == 0 ? 0.0 : ((p - a).dot(ab) / l).clamp(0.0, 1.0);
  return p.distanceTo(a + ab * t);
}

bool _segmentsCross(InkVec a, InkVec b, InkVec c, InkVec d) {
  final d1 = (b - a).cross(c - a), d2 = (b - a).cross(d - a);
  final d3 = (d - c).cross(a - c), d4 = (d - c).cross(b - c);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double segmentDistance(InkVec a, InkVec b, InkVec c, InkVec d) {
  if (_segmentsCross(a, b, c, d)) return 0;
  return [
    distanceToSegment(a, c, d),
    distanceToSegment(b, c, d),
    distanceToSegment(c, a, b),
    distanceToSegment(d, a, b),
  ].reduce(math.min);
}

/// The distance from the segment [a]-[b] to an axis-aligned rectangle.
double rectDistance(
  InkVec a,
  InkVec b,
  double l,
  double t,
  double r,
  double bo,
) {
  bool inside(InkVec p) => p.x >= l && p.x <= r && p.y >= t && p.y <= bo;
  if (inside(a) || inside(b)) return 0;
  final c = [InkVec(l, t), InkVec(r, t), InkVec(r, bo), InkVec(l, bo)];
  var best = double.infinity;
  for (var i = 0; i < 4; i++) {
    best = math.min(best, segmentDistance(a, b, c[i], c[(i + 1) % 4]));
  }
  return best;
}

/// Whether [p] is inside the closed polygon [poly] (even-odd).
bool insidePolygon(InkVec p, List<InkVec> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.y > p.y) != (b.y > p.y) &&
        p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// The convex hull, counterclockwise in a y-up frame (positive signed area).
List<InkVec> convexHull(List<InkVec> points) {
  final p = [...points]
    ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  if (p.length < 3) return p;
  double turn(InkVec o, InkVec a, InkVec b) => (a - o).cross(b - o);
  final lower = <InkVec>[], upper = <InkVec>[];
  for (final q in p) {
    while (lower.length >= 2 &&
        turn(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  for (final q in p.reversed) {
    while (upper.length >= 2 &&
        turn(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  return [...lower..removeLast(), ...upper..removeLast()];
}

// Node fitting ---------------------------------------------------------------

/// Fits editable nodes to raw sample positions (page units).
///
/// The result is a chain of cubic segments whose largest distance to the
/// samples, and to the straight lines between them, stays within
/// [InkSettings.fitTolerance]. Nodes sit exactly on samples and keep their
/// sample index, so the raw samples stay the linked source. A sharp change of
/// direction becomes a corner node; other joins are smooth. If the nodes
/// would exceed [maxNodes], the tolerance doubles until they fit.
List<InkNode> fitNodes(
  List<InkVec> samples, {
  InkSettings settings = const InkSettings(),
  int maxNodes = 1000,
}) {
  // Repeated positions carry no shape. Keep the first sample of each run.
  final points = <InkVec>[], index = <int>[];
  for (var i = 0; i < samples.length; i++) {
    if (points.isEmpty || points.last != samples[i]) {
      points.add(samples[i]);
      index.add(i);
    }
  }
  if (points.isEmpty) return const [];
  if (points.length == 1) {
    return [InkNode.at(points.first, sample: index.first)];
  }
  final corners = _corners(points, settings);
  var tolerance = settings.fitTolerance;
  while (true) {
    final segments = <CubicSegment>[];
    final joints = <int>[0];
    for (var c = 0; c + 1 < corners.length; c++) {
      final a = corners[c], b = corners[c + 1];
      _fit(
        points,
        a,
        b,
        _tangent(points, a, 1, settings),
        _tangent(points, b, -1, settings),
        tolerance,
        segments,
        joints,
      );
    }
    if (segments.length + 1 <= maxNodes || segments.length < 2) {
      return _nodes(segments, joints, corners.toSet(), index);
    }
    tolerance *= 2;
  }
}

List<InkNode> _nodes(
  List<CubicSegment> segments,
  List<int> joints,
  Set<int> corners,
  List<int> index,
) {
  final nodes = <InkNode>[];
  for (var i = 0; i <= segments.length; i++) {
    final at = i < segments.length ? segments[i].p0 : segments[i - 1].p3;
    final inner = i > 0 && i < segments.length;
    final corner = inner && corners.contains(joints[i]);
    nodes.add(
      InkNode.at(
        at,
        incoming: i > 0 ? segments[i - 1].p2 : null,
        outgoing: i < segments.length ? segments[i].p1 : null,
        mode: corner ? NodeMode.independent : NodeMode.smooth,
        corner: corner,
        sample: index[joints[i]],
      ),
    );
  }
  return nodes;
}

/// Indexes that split the samples into smooth runs: both ends and the sharp
/// corners, measured over [InkSettings.cornerWindow] on each side.
List<int> _corners(List<InkVec> p, InkSettings s) {
  final out = <int>[0];
  final angle = List<double>.filled(p.length, 0);
  for (var i = 1; i < p.length - 1; i++) {
    final back = _reach(p, i, -1, s.cornerWindow);
    final ahead = _reach(p, i, 1, s.cornerWindow);
    final u = (p[i] - p[back]).normalized(), v = (p[ahead] - p[i]).normalized();
    angle[i] = math.acos(u.dot(v).clamp(-1.0, 1.0));
  }
  for (var i = 1; i < p.length - 1; i++) {
    if (angle[i] <= s.cornerAngle) continue;
    // Keep only the sharpest sample inside its window.
    final from = _reach(p, i, -1, s.cornerWindow);
    final to = _reach(p, i, 1, s.cornerWindow);
    var best = true;
    for (var k = from; k <= to; k++) {
      if (angle[k] > angle[i] || (angle[k] == angle[i] && k < i)) best = false;
    }
    if (best && i - out.last >= 1) out.add(i);
  }
  out.add(p.length - 1);
  return out;
}

/// The first index from [i] in direction [dir] at [distance] or more, or the
/// end of the samples.
int _reach(List<InkVec> p, int i, int dir, double distance) {
  var k = i;
  while (k + dir >= 0 && k + dir < p.length) {
    k += dir;
    if (p[k].distanceTo(p[i]) >= distance) break;
  }
  return k;
}

/// The direction into the run at [i], toward [dir], over a short distance so
/// that one jittery sample does not turn the end of the curve.
InkVec _tangent(List<InkVec> p, int i, int dir, InkSettings s) {
  final k = _reach(p, i, dir, s.fitTolerance * 2);
  return (p[k] - p[i]).normalized();
}

void _fit(
  List<InkVec> p,
  int first,
  int last,
  InkVec t1,
  InkVec t2,
  double tolerance,
  List<CubicSegment> out,
  List<int> joints,
) {
  final dist = p[first].distanceTo(p[last]);
  if (last - first == 1) {
    // Two samples: keep the end directions, with handles short enough that
    // the curve stays within the tolerance of the straight line between them.
    var length = dist / 3;
    CubicSegment line() => CubicSegment(
      p[first],
      p[first] + t1 * length,
      p[last] + t2 * length,
      p[last],
    );
    var seg = line();
    while (length > 1e-9 && _chordError(seg) > tolerance) {
      length /= 2;
      seg = line();
    }
    out.add(seg);
    joints.add(last);
    return;
  }
  var u = _chordParameters(p, first, last);
  var seg = _bezier(p, first, last, u, t1, t2);
  var (error, split) = _maxError(p, first, last, seg, u);
  if (error <= tolerance) {
    out.add(seg);
    joints.add(last);
    return;
  }
  if (error <= tolerance * 4) {
    for (var k = 0; k < 4; k++) {
      u = _reparameterize(p, first, last, u, seg);
      seg = _bezier(p, first, last, u, t1, t2);
      (error, split) = _maxError(p, first, last, seg, u);
      if (error <= tolerance) {
        out.add(seg);
        joints.add(last);
        return;
      }
    }
  }
  final center = (p[split - 1] - p[split + 1]).normalized();
  final c = center.length == 0
      ? (p[split - 1] - p[split]).normalized()
      : center;
  _fit(p, first, split, t1, c, tolerance, out, joints);
  _fit(p, split, last, -c, t2, tolerance, out, joints);
}

double _chordError(CubicSegment seg) {
  var error = 0.0;
  for (var k = 1; k < 16; k++) {
    final e = distanceToSegment(seg.at(k / 16), seg.p0, seg.p3);
    if (e > error) error = e;
  }
  return error;
}

List<double> _chordParameters(List<InkVec> p, int first, int last) {
  final u = <double>[0];
  for (var i = first + 1; i <= last; i++) {
    u.add(u.last + p[i].distanceTo(p[i - 1]));
  }
  final total = u.last;
  return [for (final v in u) total == 0 ? 0.0 : v / total];
}

/// The least-squares cubic with fixed end points and end directions
/// (Schneider, "An Algorithm for Automatically Fitting Digitized Curves").
CubicSegment _bezier(
  List<InkVec> p,
  int first,
  int last,
  List<double> u,
  InkVec t1,
  InkVec t2,
) {
  final p0 = p[first], p3 = p[last];
  var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0;
  for (var i = 0; i <= last - first; i++) {
    final t = u[i], s = 1 - t;
    final b0 = s * s * s, b1 = 3 * s * s * t, b2 = 3 * s * t * t;
    final b3 = t * t * t;
    final a1 = t1 * b1, a2 = t2 * b2;
    c00 += a1.dot(a1);
    c01 += a1.dot(a2);
    c11 += a2.dot(a2);
    final tmp = p[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
    x0 += a1.dot(tmp);
    x1 += a2.dot(tmp);
  }
  final det = c00 * c11 - c01 * c01;
  final dist = p0.distanceTo(p3);
  var alpha1 = det == 0 ? 0.0 : (x0 * c11 - x1 * c01) / det;
  var alpha2 = det == 0 ? 0.0 : (c00 * x1 - c01 * x0) / det;
  final epsilon = 1e-6 * dist;
  if (alpha1 < epsilon || alpha2 < epsilon) {
    alpha1 = alpha2 = dist / 3;
  }
  return CubicSegment(p0, p0 + t1 * alpha1, p3 + t2 * alpha2, p3);
}

List<double> _reparameterize(
  List<InkVec> p,
  int first,
  int last,
  List<double> u,
  CubicSegment seg,
) => [for (var i = 0; i <= last - first; i++) _newton(seg, p[first + i], u[i])];

double _newton(CubicSegment seg, InkVec point, double u) {
  final d = seg.at(u) - point;
  final d1 = seg.derivative(u), d2 = seg.secondDerivative(u);
  final denominator = d1.dot(d1) + d.dot(d2);
  if (denominator == 0) return u;
  return (u - d.dot(d1) / denominator).clamp(0.0, 1.0);
}

/// The largest error and the sample to split at. It measures each sample to
/// its curve point, and each curve point between two samples to the straight
/// line between them, so the curve cannot bulge away between samples.
(double, int) _maxError(
  List<InkVec> p,
  int first,
  int last,
  CubicSegment seg,
  List<double> u,
) {
  var error = 0.0;
  var split = (first + last) ~/ 2;
  for (var i = 1; i < last - first; i++) {
    final e = seg.at(u[i]).distanceTo(p[first + i]);
    if (e > error) {
      error = e;
      split = first + i;
    }
  }
  for (var i = 0; i < last - first; i++) {
    final mid = seg.at((u[i] + u[i + 1]) / 2);
    final e = distanceToSegment(mid, p[first + i], p[first + i + 1]);
    if (e > error) {
      error = e;
      split = (first + i).clamp(first + 1, last - 1);
    }
  }
  return (error, split);
}

/// The cubic from [start] to [end] with the given end directions that is
/// closest to [points] (least squares, chord-length parameters).
CubicSegment fitSegment(
  List<InkVec> points,
  InkVec startDirection,
  InkVec endDirection,
) {
  final u = _chordParameters(points, 0, points.length - 1);
  return _bezier(
    points,
    0,
    points.length - 1,
    u,
    startDirection.normalized(),
    endDirection.normalized(),
  );
}

/// The raw sample position (a fractional sample index) of every path position
/// `u`. Each node links to the sample it was fitted at; between two nodes the
/// position moves evenly. Nodes without a valid, ordered link spread over the
/// samples by their order, so pressure still follows the path.
double Function(double u) sampleMap(List<InkNode> nodes, int sampleCount) {
  final last = math.max(0, sampleCount - 1).toDouble();
  final linked = <double>[];
  for (var i = 0; i < nodes.length; i++) {
    final s = nodes[i].sample;
    if (s == null ||
        s < 0 ||
        s > last ||
        (linked.isNotEmpty && s < linked.last)) {
      linked.clear();
      break;
    }
    linked.add(s.toDouble());
  }
  final at = linked.length == nodes.length && nodes.isNotEmpty
      ? linked
      : [
          for (var i = 0; i < nodes.length; i++)
            nodes.length == 1 ? 0.0 : last * i / (nodes.length - 1),
        ];
  return (u) {
    if (at.length < 2) return at.isEmpty ? 0 : at.first;
    final i = math.min(u.floor(), at.length - 2).clamp(0, at.length - 2);
    final t = (u - i).clamp(0.0, 1.0);
    return at[i] + (at[i + 1] - at[i]) * t;
  };
}

/// The value of an integer sample column at a fractional sample position.
double columnAt(List<int> column, double position) {
  final i = position.floor().clamp(0, column.length - 1);
  final j = math.min(i + 1, column.length - 1);
  final t = position - i;
  return column[i] + (column[j] - column[i]) * t;
}
