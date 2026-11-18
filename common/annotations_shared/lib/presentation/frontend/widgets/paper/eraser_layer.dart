import 'package:flutter/material.dart';

import '../../components/tokens.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';

/// The circle of the eraser while it erases (B6.6: a circular tip). Red in
/// delete-anything mode.
class EraserLayer extends StatelessWidget {
  final DrawHandler draw;
  final PaperView view;
  const EraserLayer({super.key, required this.draw, required this.view});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: draw.eraserAt,
    builder: (context, at, _) {
      if (at == null) return const SizedBox.shrink();
      final (center, radius) = at;
      final c = context.colors;
      return IgnorePointer(
        child: CustomPaint(
          key: const Key('eraser-circle'),
          size: Size.infinite,
          painter: _CirclePainter(
            view.toScreen(Offset(center.x, center.y)),
            radius * view.zoom,
            draw.dangerous ? c.danger : c.textSecondary,
          ),
        ),
      );
    },
  );
}

class _CirclePainter extends CustomPainter {
  _CirclePainter(this.center, this.radius, this.color);
  final Offset center;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CirclePainter old) =>
      old.center != center || old.radius != radius || old.color != color;
}
