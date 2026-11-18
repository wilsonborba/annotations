import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/paper_settings.dart';
import '../../../domain/services/paper_page.dart';
import 'tokens.dart';

/// The neutral colors of the paper (H7 2.8, B4.4). The paper follows the
/// light or dark mode; ink and text colors stored in a note never change.
@immutable
final class PaperColors {
  const PaperColors({
    required this.desk,
    required this.paper,
    required this.guide,
  });

  factory PaperColors.of(AppColors c) => PaperColors(
    desk: c.isDark ? c.page : c.subtle,
    paper: c.isDark ? c.surface : c.page,
    guide: c.control,
  );

  /// The area around the page.
  final Color desk;

  /// The page itself: natural paper without a border.
  final Color paper;

  /// Lines and dots at full visibility, before [PaperSettings.maxGuideAlpha].
  final Color guide;
}

/// Draws the [lines] of [guides] in page units on a canvas that is already
/// scaled by [zoom], inside [clip] (page units). Line width and dot size stay
/// fine at every zoom; the spacing follows the page.
void paintGuides(
  Canvas canvas,
  PaperGuides guides,
  GuideLines lines, {
  required double zoom,
  required Rect clip,
  required Color color,
  PaperSettings settings = const PaperSettings(),
}) {
  final spacing = guides.spacing?.toDouble() ?? 0;
  final visibility = (guides.visibility ?? 0).toDouble().clamp(0.0, 1.0);
  if (spacing <= 0 || visibility <= 0) return;
  final screenSpacing = spacing * zoom;
  final fade = ((screenSpacing - 2) / (settings.guideFadeBelow - 2)).clamp(
    0.0,
    1.0,
  );
  final alpha = settings.maxGuideAlpha * visibility * fade;
  if (alpha <= 0) return;
  final paint = Paint()
    ..color = color.withValues(alpha: alpha)
    ..isAntiAlias = true;
  switch (guides.pattern) {
    case PaperPattern.blank:
      return;
    case PaperPattern.ruled || PaperPattern.grid:
      // One page unit wide, kept between half a pixel and two pixels.
      paint.strokeWidth = 1.0.clamp(0.5 / zoom, 2 / zoom);
      for (final y in lines.rows) {
        canvas.drawLine(Offset(clip.left, y), Offset(clip.right, y), paint);
      }
      for (final x in lines.columns) {
        canvas.drawLine(Offset(x, clip.top), Offset(x, clip.bottom), paint);
      }
    case PaperPattern.dots:
      final r = 1.2.clamp(0.6 / zoom, 3 / zoom);
      final dots = <Offset>[
        for (final y in lines.rows)
          for (final x in lines.columns) Offset(x, y),
      ];
      paint
        ..strokeWidth = r * 2
        ..strokeCap = StrokeCap.round;
      canvas.drawPoints(ui.PointMode.points, dots, paint);
  }
}

/// A small sample of one background for its choice in the paper panel.
class PaperSwatch extends StatelessWidget {
  final PaperGuides guides;
  final Size size;
  const PaperSwatch({
    super.key,
    required this.guides,
    this.size = const Size(64, 44),
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: size,
    painter: _SwatchPainter(guides, PaperColors.of(context.colors)),
  );
}

class _SwatchPainter extends CustomPainter {
  final PaperGuides guides;
  final PaperColors colors;
  _SwatchPainter(this.guides, this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = colors.paper);
    // The sample uses its own spacing so each pattern reads at this size.
    final sample = guides.pattern == PaperPattern.blank
        ? guides
        : PaperGuides(guides.pattern, spacing: 10, visibility: 1);
    final lines = const PaperPage().lines(
      sample,
      width: size.width + 1,
      left: 0,
      top: 0,
      right: size.width,
      bottom: size.height,
    );
    canvas.save();
    canvas.clipRect(rect);
    paintGuides(
      canvas,
      sample,
      lines,
      zoom: 1,
      clip: rect,
      color: colors.guide,
      settings: const PaperSettings(maxGuideAlpha: 0.8),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.guides != guides || old.colors.paper != colors.paper;
}
