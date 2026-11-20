import 'dart:math';

import 'package:flutter/material.dart';

/// The pen of the drawn style (owner design review 2026-11-20): lines that
/// wander a little, the same way on every paint for one seed, like the
/// Engineering diagrams.
/// The points of a pen line from [a] to [b] that wanders a little, the same
/// way on every paint for one [random] seed.
List<Offset> penLine(Offset a, Offset b, Random random, double wobble) {
  final length = (b - a).distance;
  final steps = max(2, (length / 18).round());
  final normal = length == 0
      ? Offset.zero
      : Offset(-(b - a).dy / length, (b - a).dx / length);
  return [
    for (var i = 0; i <= steps; i++)
      Offset.lerp(a, b, i / steps)! +
          normal *
              ((i == 0 || i == steps ? 0.3 : 1) *
                  (random.nextDouble() - .5) *
                  wobble),
  ];
}

Path smoothPath(List<Offset> points) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length - 1; i++) {
    final mid = Offset.lerp(points[i], points[i + 1], .5)!;
    path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(points.last.dx, points.last.dy);
  return path;
}

Paint penPaint(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

/// Draws pen shapes on a canvas in a design box: every coordinate is in
/// [box] units and scales to the paint size, so an illustration keeps its
/// proportions at every width.
class Pen {
  Pen(this.canvas, Size size, {required Size box, int seed = 1})
    : scale = min(size.width / box.width, size.height / box.height),
      random = Random(seed) {
    final used = Size(box.width * scale, box.height * scale);
    canvas.save();
    canvas.translate(
      (size.width - used.width) / 2,
      (size.height - used.height) / 2,
    );
    canvas.scale(scale);
  }

  final Canvas canvas;
  final double scale;
  final Random random;

  void done() => canvas.restore();

  /// A wandering line through [points].
  void line(
    List<Offset> points,
    Color color, {
    double width = 2.2,
    double wobble = 2,
  }) {
    final all = <Offset>[];
    for (var i = 0; i < points.length - 1; i++) {
      final part = penLine(points[i], points[i + 1], random, wobble);
      all.addAll(i == 0 ? part : part.skip(1));
    }
    canvas.drawPath(smoothPath(all), penPaint(color, width));
  }

  /// A closed shape drawn as two passes, like a hand-drawn box.
  void rect(Rect r, Color color, {double width = 2.2, Color? fill}) {
    if (fill != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(6)),
        Paint()..color = fill,
      );
    }
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    for (final pass in [0, 1]) {
      for (var i = 0; i < 4; i++) {
        line(
          [
            corners[i] + Offset(pass * 1.2, pass * -.8),
            corners[(i + 1) % 4] + Offset(pass * -.6, pass * 1.0),
          ],
          pass == 0 ? color : color.withValues(alpha: .45),
          width: pass == 0 ? width : width * .6,
        );
      }
    }
  }

  /// A loop drawn around [r], overlapping its start like a pen circle.
  void loop(Rect r, Color color, {double width = 2.6, double turns = 1.12}) {
    final c = r.center;
    final points = [
      for (var i = 0; i <= 36; i++)
        c +
            Offset(
                  r.width / 2 * cos(-pi / 2 + i * turns * 2 * pi / 36),
                  r.height / 2 * sin(-pi / 2 + i * turns * 2 * pi / 36),
                ) *
                (1 + (random.nextDouble() - .5) * .04),
    ];
    canvas.drawPath(smoothPath(points), penPaint(color, width));
  }

  /// A filled solid dot or disc.
  void dot(Offset at, double radius, Color color) =>
      canvas.drawCircle(at, radius, Paint()..color = color);

  /// A broad, translucent highlighter mark.
  void highlight(Offset a, Offset b, Color color, {double width = 14}) =>
      canvas.drawPath(
        smoothPath(penLine(a, b, random, 2)),
        penPaint(color.withValues(alpha: .55), width),
      );

  /// Hand-written text: wavy lines that read as words, never real text.
  void writing(Offset start, double length, Color color, {double width = 1.8}) {
    final points = <Offset>[];
    var x = 0.0;
    while (x < length) {
      final word = 14 + random.nextDouble() * 26;
      for (var i = 0; i <= 6 && x + word * i / 6 <= length; i++) {
        points.add(
          start + Offset(x + word * i / 6, sin(i * 1.9) * 3 - (i % 3) * .8),
        );
      }
      x += word + 8;
      if (x < length) {
        canvas.drawPath(smoothPath(points), penPaint(color, width));
        points.clear();
      }
    }
    if (points.length > 1) {
      canvas.drawPath(smoothPath(points), penPaint(color, width));
    }
  }

  /// A tick mark.
  void check(Offset at, double size, Color color, {double width = 2.6}) => line(
    [at, at + Offset(size * .35, size * .4), at + Offset(size, -size * .5)],
    color,
    width: width,
    wobble: .8,
  );

  /// An arrow from [a] to [b] with a two-stroke head.
  void arrow(Offset a, Offset b, Color color, {double width = 2.2}) {
    line(
      [a, Offset.lerp(a, b, .5)! + const Offset(0, -6), b],
      color,
      width: width,
    );
    final d = (b - a) / (b - a).distance;
    final n = Offset(-d.dy, d.dx);
    line([b, b - d * 12 + n * 7], color, width: width, wobble: .5);
    line([b, b - d * 12 - n * 7], color, width: width, wobble: .5);
  }
}
