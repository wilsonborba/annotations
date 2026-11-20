import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/landing_settings.dart';
import 'scope.dart';
import 'sketch_pen.dart';
import 'tokens.dart';

/// A diagram with a handwritten look, drawn in code (58edb2df): boxes with
/// pen-drawn borders and arrows between stages. The labels are Ubuntu Sans
/// text, so they stay readable and translated. A part with a repository is
/// a link to its tagged public source.
class SketchDiagram extends StatelessWidget {
  const SketchDiagram({
    super.key,
    required this.name,
    required this.stages,
    required this.onOpen,
  });

  /// Names the diagram for keys, such as `architecture`.
  final String name;
  final List<List<DiagramPart>> stages;
  final ValueChanged<PublicRepo> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // Side by side when every stage has room for a readable box.
      final across = c.maxWidth >= stages.length * 190;
      final children = <Widget>[];
      for (var i = 0; i < stages.length; i++) {
        if (i > 0) {
          children.add(SketchArrow(down: !across, seed: name.hashCode + i));
        }
        final boxes = [
          for (final part in stages[i])
            SketchBox(
              key: Key('diagram-$name-${part.label}'),
              part: part,
              onOpen: onOpen,
            ),
        ];
        children.add(
          across
              ? Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var j = 0; j < boxes.length; j++) ...[
                        if (j > 0) const SizedBox(height: 12),
                        boxes[j],
                      ],
                    ],
                  ),
                )
              : Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final box in boxes)
                      ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 150),
                        child: box,
                      ),
                  ],
                ),
        );
      }
      return Semantics(
        container: true,
        child: across
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: children,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
      );
    },
  );
}

/// One part of a diagram in a pen-drawn box.
class SketchBox extends StatelessWidget {
  const SketchBox({super.key, required this.part, required this.onOpen});

  final DiagramPart part;
  final ValueChanged<PublicRepo> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final repo = part.repo;
    final body = CustomPaint(
      painter: SketchBoxPainter(color: c.text, seed: part.label.hashCode),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr(part.label),
              textAlign: TextAlign.center,
              style: text.titleSmall,
            ),
            if (repo != null) ...[
              const SizedBox(height: 4),
              Text(
                '${repo.name} ${repo.tag}',
                textAlign: TextAlign.center,
                style: text.bodySmall!.copyWith(
                  color: c.link,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: c.link,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (repo == null) return body;
    return Semantics(
      link: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onOpen(repo),
        child: body,
      ),
    );
  }
}

/// A pen-drawn arrow from one stage to the next.
class SketchArrow extends StatelessWidget {
  const SketchArrow({super.key, required this.down, required this.seed});

  final bool down;
  final int seed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: down ? double.infinity : 44,
    height: down ? 40 : 30,
    child: CustomPaint(
      painter: SketchArrowPainter(
        color: context.colors.textSecondary,
        down: down,
        seed: seed,
      ),
    ),
  );
}

/// A box border drawn as two pen passes, like a hand-drawn rectangle.
class SketchBoxPainter extends CustomPainter {
  const SketchBoxPainter({required this.color, required this.seed});

  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final r = Offset.zero & size;
    final corners = [
      r.topLeft + const Offset(2, 2),
      r.topRight + const Offset(-2, 2),
      r.bottomRight + const Offset(-2, -2),
      r.bottomLeft + const Offset(2, -2),
    ];
    for (final (pass, width, alpha) in const [(0, 1.7, 1.0), (1, 1.0, .45)]) {
      final paint = penPaint(color.withValues(alpha: alpha), width);
      for (var i = 0; i < 4; i++) {
        // The second pass overshoots the corners a little, as a pen does.
        final a = corners[i] + Offset(pass * 1.2, pass * -.8);
        final b = corners[(i + 1) % 4] + Offset(pass * -.6, pass * 1.0);
        canvas.drawPath(smoothPath(penLine(a, b, random, 2.4)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(SketchBoxPainter old) =>
      old.color != color || old.seed != seed;
}

/// An arrow drawn with one pen line and a two-stroke head.
class SketchArrowPainter extends CustomPainter {
  const SketchArrowPainter({
    required this.color,
    required this.down,
    required this.seed,
  });

  final Color color;
  final bool down;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final paint = penPaint(color, 1.8);
    final a = down ? Offset(size.width / 2, 4) : Offset(4, size.height / 2);
    final b = down
        ? Offset(size.width / 2, size.height - 4)
        : Offset(size.width - 4, size.height / 2);
    canvas.drawPath(smoothPath(penLine(a, b, random, 3)), paint);
    final back = down ? const Offset(0, -9) : const Offset(-9, 0);
    final side = down ? const Offset(6, 0) : const Offset(0, 6);
    canvas.drawPath(
      smoothPath(penLine(b, b + back + side, random, 1.2)),
      paint,
    );
    canvas.drawPath(
      smoothPath(penLine(b, b + back - side, random, 1.2)),
      paint,
    );
  }

  @override
  bool shouldRepaint(SketchArrowPainter old) =>
      old.color != color || old.down != down || old.seed != seed;
}
