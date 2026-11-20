import 'package:flutter/material.dart';

import 'sketch_pen.dart';
import 'tokens.dart';

/// The illustrations of the landing, drawn in code with the pen style of
/// the Engineering diagrams (owner design review 2026-11-20). They hold no
/// real text: hand-written marks only, so every language reads the same.
enum SketchScene {
  writing,
  chart,
  tasks,
  notes,
  instant,
  study,
  sharing,
  emptyDesk,
  hourglass,
  emptyShelf,
}

/// The colours of one drawing, from the theme: ink, paper and the H7
/// accents (purple and green in both themes, a pair per Features group).
class SketchColors {
  SketchColors.of(BuildContext context, {(Color, Color)? pair})
    : ink = context.colors.text,
      faint = context.colors.textSecondary,
      paper = context.colors.surface,
      line = context.colors.border,
      purple = AppPalette.purple,
      // Green lines need the darker mark on light paper (H7 rule 3).
      green = context.colors.isDark
          ? AppPalette.green
          : context.colors.selectionOutline,
      greenFill = AppPalette.green,
      accent = pair?.$1 ?? AppPalette.green,
      accent2 = pair?.$2 ?? AppPalette.purple;

  final Color ink, faint, paper, line, purple, green, greenFill;
  final Color accent, accent2;
}

/// One illustration in a 400 by 260 design box.
class SketchArt extends StatelessWidget {
  const SketchArt(this.scene, {super.key, this.pair, this.ratio = 400 / 260});

  final SketchScene scene;
  final (Color, Color)? pair;
  final double ratio;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: ratio,
    child: Semantics(
      image: true,
      excludeSemantics: true,
      child: CustomPaint(
        key: Key('sketch-${scene.name}'),
        painter: SketchScenePainter(
          scene,
          SketchColors.of(context, pair: pair),
        ),
      ),
    ),
  );
}

class SketchScenePainter extends CustomPainter {
  SketchScenePainter(this.scene, this.c);

  final SketchScene scene;
  final SketchColors c;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Pen(
      canvas,
      size,
      box: const Size(400, 260),
      seed: scene.index + 7,
    );
    switch (scene) {
      case SketchScene.writing:
        _writing(pen);
      case SketchScene.chart:
        _chart(pen);
      case SketchScene.tasks:
        _tasks(pen);
      case SketchScene.notes:
        _notes(pen);
      case SketchScene.instant:
        _instant(pen);
      case SketchScene.study:
        _study(pen);
      case SketchScene.sharing:
        _sharing(pen);
      case SketchScene.emptyDesk:
        _emptyDesk(pen);
      case SketchScene.hourglass:
        _hourglass(pen, const Offset(200, 130), 1);
      case SketchScene.emptyShelf:
        _emptyShelf(pen);
    }
    pen.done();
  }

  void _page(Pen p, Rect r, {int lines = 5, double from = 0}) {
    p.rect(r, c.ink, fill: c.paper);
    for (var i = 0; i < lines; i++) {
      p.writing(
        r.topLeft + Offset(22, 34 + from + i * 26),
        r.width - 44 - (i == lines - 1 ? r.width * .3 : 0),
        c.faint,
      );
    }
  }

  void _sparkle(Pen p, Offset at, Color color, [double s = 8]) {
    p.line([at - Offset(0, s), at + Offset(0, s)], color, wobble: .4);
    p.line([at - Offset(s, 0), at + Offset(s, 0)], color, wobble: .4);
  }

  void _writing(Pen p) {
    const page = Rect.fromLTWH(110, 34, 180, 196);
    _page(p, page, lines: 6);
    p.highlight(const Offset(128, 120), const Offset(240, 118), c.greenFill);
    p.loop(const Rect.fromLTWH(196, 140, 84, 30), c.purple);
    // Floating tools around the page.
    p.line([const Offset(42, 150), const Offset(86, 96)], c.ink, width: 5);
    p.line([const Offset(86, 96), const Offset(92, 88)], c.purple, width: 3);
    p.rect(const Rect.fromLTWH(320, 70, 40, 22), c.accent2);
    p.line([
      const Offset(318, 182),
      const Offset(346, 136),
      const Offset(374, 182),
      const Offset(318, 182),
    ], c.accent2);
    p.rect(const Rect.fromLTWH(34, 40, 34, 34), c.ink, fill: c.accent);
    _sparkle(p, const Offset(330, 230), c.purple);
    _sparkle(p, const Offset(70, 210), c.green, 6);
  }

  void _chart(Pen p) {
    p.rect(const Rect.fromLTWH(60, 26, 280, 210), c.ink, fill: c.paper);
    p.line([const Offset(90, 50), const Offset(90, 206)], c.ink);
    p.line([const Offset(90, 206), const Offset(320, 206)], c.ink);
    const heights = [60.0, 96.0, 74.0, 132.0, 108.0];
    for (var i = 0; i < heights.length; i++) {
      final left = 108.0 + i * 42;
      p.rect(
        Rect.fromLTWH(left, 206 - heights[i], 26, heights[i]),
        c.ink,
        fill: (i == 3 ? c.accent : c.accent2).withValues(alpha: .35),
        width: 1.8,
      );
    }
    p.line(
      [
        for (var i = 0; i < heights.length; i++)
          Offset(121.0 + i * 42, 190 - heights[i]),
      ],
      c.purple,
      width: 2.4,
    );
    p.loop(const Rect.fromLTWH(220, 52, 70, 50), c.green, width: 3);
    p.arrow(const Offset(360, 30), const Offset(300, 60), c.purple);
    p.writing(const Offset(300, 18), 70, c.purple, width: 2);
  }

  void _tasks(Pen p) {
    const card = Rect.fromLTWH(70, 28, 230, 206);
    p.rect(card, c.ink, fill: c.paper);
    for (var i = 0; i < 5; i++) {
      final y = 58.0 + i * 36;
      p.rect(Rect.fromLTWH(92, y - 10, 18, 18), c.ink, width: 1.8);
      if (i < 2) p.check(Offset(94, y), 18, c.green);
      p.writing(Offset(124, y), 140 - (i % 2) * 40, i < 2 ? c.faint : c.ink);
    }
    // A sticky note on the corner with a hand-written note.
    final note = [
      const Offset(256, 150),
      const Offset(350, 138),
      const Offset(362, 222),
      const Offset(266, 236),
      const Offset(256, 150),
    ];
    p.canvas.drawPath(
      Path()..addPolygon(note, true),
      Paint()..color = c.accent.withValues(alpha: .9),
    );
    p.line(note, c.ink);
    p.writing(const Offset(272, 178), 70, AppPalette.night, width: 2);
    p.writing(const Offset(274, 202), 50, AppPalette.night, width: 2);
  }

  void _notes(Pen p) {
    _page(p, const Rect.fromLTWH(150, 52, 160, 186), lines: 0);
    _page(p, const Rect.fromLTWH(130, 40, 160, 186), lines: 0);
    _page(p, const Rect.fromLTWH(110, 28, 160, 186), lines: 5);
    p.highlight(const Offset(128, 100), const Offset(220, 98), c.greenFill);
    // A lock: notes stay yours.
    p.rect(const Rect.fromLTWH(300, 150, 52, 42), c.purple, fill: c.paper);
    p.line([
      const Offset(312, 150),
      const Offset(312, 132),
      const Offset(326, 120),
      const Offset(340, 132),
      const Offset(340, 150),
    ], c.purple);
    p.dot(const Offset(326, 170), 4, c.purple);
  }

  void _window(Pen p, Rect r) {
    p.rect(r, c.ink, fill: c.paper);
    p.line(
      [r.topLeft + const Offset(0, 22), r.topRight + const Offset(0, 22)],
      c.ink,
      width: 1.6,
    );
    for (var i = 0; i < 3; i++) {
      p.dot(r.topLeft + Offset(14.0 + i * 12, 11), 3, c.faint);
    }
  }

  void _instant(Pen p) {
    const a = Rect.fromLTWH(24, 50, 140, 110),
        b = Rect.fromLTWH(236, 50, 140, 110);
    _window(p, a);
    _window(p, b);
    for (final r in [a, b]) {
      p.writing(r.topLeft + const Offset(16, 52), 100, c.faint);
      p.writing(r.topLeft + const Offset(16, 78), 70, c.faint);
    }
    p.highlight(
      a.topLeft + const Offset(16, 52),
      a.topLeft + const Offset(90, 52),
      c.greenFill,
      width: 10,
    );
    p.highlight(
      b.topLeft + const Offset(16, 52),
      b.topLeft + const Offset(90, 52),
      c.greenFill,
      width: 10,
    );
    p.arrow(const Offset(172, 92), const Offset(228, 92), c.purple);
    p.arrow(const Offset(228, 122), const Offset(172, 122), c.purple);
    _hourglass(p, const Offset(200, 210), .42);
  }

  void _study(Pen p) {
    // A printed page with a folded corner.
    final sheet = [
      const Offset(60, 30),
      const Offset(170, 30),
      const Offset(200, 60),
      const Offset(200, 220),
      const Offset(60, 220),
      const Offset(60, 30),
    ];
    p.canvas.drawPath(
      Path()..addPolygon(sheet, true),
      Paint()..color = c.paper,
    );
    p.line(sheet, c.ink);
    p.line(
      [const Offset(170, 30), const Offset(170, 60), const Offset(200, 60)],
      c.ink,
      width: 1.6,
    );
    for (var i = 0; i < 5; i++) {
      p.writing(Offset(78, 84.0 + i * 26), 100 - (i == 4 ? 40 : 0), c.faint);
    }
    // A quiz card with one answer chosen.
    p.rect(const Rect.fromLTWH(220, 70, 140, 150), c.ink, fill: c.paper);
    for (var i = 0; i < 3; i++) {
      final y = 106.0 + i * 36;
      p.loop(
        Rect.fromCenter(center: Offset(242, y), width: 16, height: 16),
        c.ink,
        width: 1.8,
        turns: 1.05,
      );
      if (i == 1) p.dot(Offset(242, y), 4.5, c.purple);
      p.writing(Offset(258, y), 80, c.faint);
    }
    p.check(const Offset(318, 54), 30, c.green, width: 3.4);
  }

  void _sharing(Pen p) {
    _page(p, const Rect.fromLTWH(70, 40, 150, 180), lines: 5);
    // A globe: published for everyone to read.
    const center = Offset(300, 120);
    p.loop(Rect.fromCenter(center: center, width: 120, height: 120), c.ink);
    p.loop(
      Rect.fromCenter(center: center, width: 54, height: 120),
      c.purple,
      width: 2,
    );
    p.line(
      [center - const Offset(60, 0), center + const Offset(60, 0)],
      c.ink,
      width: 1.8,
    );
    p.arrow(const Offset(222, 130), const Offset(248, 126), c.green);
    _sparkle(p, const Offset(370, 54), c.purple);
  }

  void _emptyDesk(Pen p) {
    p.line([const Offset(70, 120), const Offset(330, 118)], c.ink, width: 3);
    p.line([const Offset(90, 120), const Offset(84, 220)], c.ink);
    p.line([const Offset(310, 118), const Offset(318, 220)], c.ink);
    p.line(
      [const Offset(70, 132), const Offset(330, 130)],
      c.faint,
      width: 1.6,
    );
    _sparkle(p, const Offset(200, 70), c.purple, 7);
  }

  void _hourglass(Pen p, Offset center, double s) {
    Offset at(double x, double y) => center + Offset(x * s, y * s);
    p.line([at(-60, -100), at(60, -100)], c.ink, width: 3);
    p.line([at(-60, 100), at(60, 100)], c.ink, width: 3);
    p.line([at(-48, -100), at(-8, 0), at(-48, 100)], c.ink);
    p.line([at(48, -100), at(8, 0), at(48, 100)], c.ink);
    // All the sand is at the bottom: the time is over.
    p.canvas.drawPath(
      Path()..addPolygon([at(-40, 96), at(0, 58), at(40, 96)], true),
      Paint()..color = c.accent.withValues(alpha: .8),
    );
    p.line([at(0, 4), at(0, 56)], c.faint, width: 1.2, wobble: .3);
  }

  void _emptyShelf(Pen p) {
    p.rect(const Rect.fromLTWH(90, 30, 220, 200), c.ink);
    for (final y in [96.0, 162.0]) {
      p.line([Offset(90, y), Offset(310, y)], c.ink);
    }
    p.line(
      [const Offset(240, 226), const Offset(272, 202)],
      c.faint,
      width: 1.6,
    );
    _sparkle(p, const Offset(150, 132), c.purple, 6);
  }

  @override
  bool shouldRepaint(SketchScenePainter old) =>
      old.scene != scene || old.c.ink != c.ink || old.c.accent != c.accent;
}

/// A hand-drawn icon in a 24 by 24 box.
enum SketchGlyph {
  laptop,
  linux,
  tablet,
  phone,
  iphone,
  browser,
  key,
  board,
  timer,
  pen,
  page,
  people,
  cloud,
  lock,
  shield,
  chart,
  tasks,
  download,
  notice,
  code,
}

class SketchIcon extends StatelessWidget {
  const SketchIcon(this.glyph, {super.key, this.size = 24, this.color});

  final SketchGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _GlyphPainter(glyph, color ?? context.colors.icon),
    ),
  );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final SketchGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Pen(canvas, size, box: const Size(24, 24), seed: glyph.index);
    const w = 1.6, wb = .5;
    void l(List<Offset> pts) => p.line(pts, color, width: w, wobble: wb);
    void box(Rect r) =>
        l([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft]);
    switch (glyph) {
      case SketchGlyph.laptop:
        box(const Rect.fromLTRB(5, 5, 19, 15));
        l([const Offset(2, 19), const Offset(22, 19)]);
        l([const Offset(5, 15), const Offset(3, 19)]);
        l([const Offset(19, 15), const Offset(21, 19)]);
      case SketchGlyph.linux:
        box(const Rect.fromLTRB(3, 4, 21, 18));
        l([const Offset(7, 9), const Offset(10, 11), const Offset(7, 13)]);
        l([const Offset(12, 14), const Offset(16, 14)]);
        l([const Offset(9, 21), const Offset(15, 21)]);
      case SketchGlyph.tablet:
        box(const Rect.fromLTRB(4, 3, 20, 21));
        p.dot(const Offset(12, 18.5), 1, color);
        l([const Offset(15, 7), const Offset(10, 13)]);
      case SketchGlyph.phone:
        box(const Rect.fromLTRB(7, 2, 17, 22));
        p.dot(const Offset(12, 19), 1, color);
      case SketchGlyph.iphone:
        box(const Rect.fromLTRB(7, 2, 17, 22));
        l([const Offset(10.5, 4.5), const Offset(13.5, 4.5)]);
      case SketchGlyph.browser:
        box(const Rect.fromLTRB(2, 4, 22, 20));
        l([const Offset(2, 8), const Offset(22, 8)]);
        p.dot(const Offset(4.5, 6), .8, color);
        p.dot(const Offset(7, 6), .8, color);
      case SketchGlyph.key:
        p.loop(const Rect.fromLTWH(3, 8, 8, 8), color, width: w);
        l([const Offset(11, 12), const Offset(21, 12)]);
        l([const Offset(18, 12), const Offset(18, 16)]);
        l([const Offset(21, 12), const Offset(21, 15)]);
      case SketchGlyph.board:
        box(const Rect.fromLTRB(3, 3, 21, 17));
        box(const Rect.fromLTRB(6, 6, 11, 11));
        l([const Offset(13, 7), const Offset(18, 7)]);
        l([const Offset(13, 10), const Offset(17, 10)]);
        l([const Offset(8, 17), const Offset(6, 22)]);
        l([const Offset(16, 17), const Offset(18, 22)]);
      case SketchGlyph.timer:
        p.loop(const Rect.fromLTWH(4, 5, 16, 16), color, width: w);
        l([const Offset(12, 13), const Offset(12, 8.5)]);
        l([const Offset(12, 13), const Offset(15, 15)]);
        l([const Offset(10, 2), const Offset(14, 2)]);
      case SketchGlyph.pen:
        l([const Offset(4, 20), const Offset(17, 7)]);
        l([const Offset(15, 5), const Offset(19, 9)]);
        l([const Offset(4, 20), const Offset(3, 21)]);
        l([const Offset(6, 18), const Offset(8, 20)]);
      case SketchGlyph.page:
        l([
          const Offset(5, 2),
          const Offset(14, 2),
          const Offset(19, 7),
          const Offset(19, 22),
          const Offset(5, 22),
          const Offset(5, 2),
        ]);
        l([const Offset(8, 12), const Offset(16, 12)]);
        l([const Offset(8, 16), const Offset(14, 16)]);
      case SketchGlyph.people:
        p.loop(const Rect.fromLTWH(5, 3, 7, 7), color, width: w);
        p.loop(const Rect.fromLTWH(13, 5, 6, 6), color, width: w);
        l([
          const Offset(2, 21),
          const Offset(4, 14),
          const Offset(12, 13),
          const Offset(14, 21),
        ]);
        l([const Offset(15, 14), const Offset(20, 14), const Offset(22, 20)]);
      case SketchGlyph.cloud:
        l([
          const Offset(6, 18),
          const Offset(3, 14),
          const Offset(6, 10),
          const Offset(10, 6),
          const Offset(15, 8),
          const Offset(20, 10),
          const Offset(21, 15),
          const Offset(18, 18),
          const Offset(6, 18),
        ]);
      case SketchGlyph.lock:
        box(const Rect.fromLTRB(5, 11, 19, 21));
        l([
          const Offset(8, 11),
          const Offset(8, 7),
          const Offset(12, 4),
          const Offset(16, 7),
          const Offset(16, 11),
        ]);
      case SketchGlyph.shield:
        l([
          const Offset(12, 2),
          const Offset(20, 5),
          const Offset(19, 13),
          const Offset(12, 22),
          const Offset(5, 13),
          const Offset(4, 5),
          const Offset(12, 2),
        ]);
        p.check(const Offset(8.5, 12), 7, color, width: w);
      case SketchGlyph.chart:
        l([const Offset(3, 3), const Offset(3, 21), const Offset(21, 21)]);
        box(const Rect.fromLTRB(6, 13, 9, 21));
        box(const Rect.fromLTRB(11, 8, 14, 21));
        box(const Rect.fromLTRB(16, 11, 19, 21));
      case SketchGlyph.tasks:
        box(const Rect.fromLTRB(3, 4, 8, 9));
        p.check(const Offset(3.5, 6.5), 5, color, width: w);
        l([const Offset(11, 6.5), const Offset(21, 6.5)]);
        box(const Rect.fromLTRB(3, 14, 8, 19));
        l([const Offset(11, 16.5), const Offset(19, 16.5)]);
      case SketchGlyph.download:
        l([const Offset(12, 3), const Offset(12, 16)]);
        l([const Offset(7, 11), const Offset(12, 16), const Offset(17, 11)]);
        l([const Offset(4, 21), const Offset(20, 21)]);
      case SketchGlyph.notice:
        l([
          const Offset(12, 3),
          const Offset(22, 20),
          const Offset(2, 20),
          const Offset(12, 3),
        ]);
        l([const Offset(12, 9), const Offset(12, 14)]);
        p.dot(const Offset(12, 17), 1, color);
      case SketchGlyph.code:
        l([const Offset(8, 6), const Offset(3, 12), const Offset(8, 18)]);
        l([const Offset(16, 6), const Offset(21, 12), const Offset(16, 18)]);
        l([const Offset(14, 4), const Offset(10, 20)]);
    }
    p.done();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

/// The coloured tile behind a group icon: a light fill with a dark icon
/// (H7 colour pairs, never light text on light paper).
class IconTile extends StatelessWidget {
  const IconTile(this.glyph, {super.key, required this.fill, this.size = 44});

  final SketchGlyph glyph;
  final Color fill;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SketchIcon(glyph, size: size * .55, color: AppPalette.night),
  );
}
