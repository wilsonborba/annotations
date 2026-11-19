/// The layouts of the cards on paper (annotations#34, B3 owner choices,
/// option B for every card). One layout both draws a card and measures its
/// height, so the stored height of a card whose text wraps is the height it
/// is drawn with (type C: a taller card must still fit).
///
/// - Link card: the full title, on more lines when narrow; the site below.
/// - Website and YouTube cards, three levels by width: at
///   [CardLevels.pictureLeft] and wider a small picture on the left; from
///   [CardLevels.pictureTop] the picture on top; narrower no picture. No
///   picture at any width when the site gave none. Pictures keep their shape.
/// - File card: the full file name, then the type and the size.
/// - CSV table: the rows in a scrolling area. PDF: the page shape.
/// - Picture: the picture in its box, keeping its shape.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../../domain/services/card_content.dart';
import '../handlers/attachment_cache.dart';
import 'icons.dart';
import 'tokens.dart';

/// The card widths where website and YouTube cards change level. Chosen in
/// the design work (B3 left them open; the example page changed at about
/// 340 to 360 and had no third level).
abstract final class CardLevels {
  static const double pictureLeft = 400;
  static const double pictureTop = 240;

  /// The small picture on the left, 16:9.
  static const double sidePicture = 128;
}

const _pad = 12.0;
const _gap = 4.0;
const _radius = 8.0;
const _cardKinds = {
  'link_card',
  'website_card',
  'youtube_card',
  'file_card',
  'csv_table',
  'pdf_preview',
  'image',
};

/// Whether [kind] is drawn by [CardLayout].
bool isCardKind(Object? kind) => _cardKinds.contains(kind);

/// The text style and colors of the cards.
final class CardStyle {
  const CardStyle({required this.text, required this.colors});
  final TextStyle text;
  final AppColors colors;

  TextStyle get title => text.copyWith(
    color: colors.text,
    fontWeight: FontWeight.w600,
    fontSize: 16,
    height: 1.3,
  );
  TextStyle get secondary =>
      text.copyWith(color: colors.textSecondary, fontSize: 13, height: 1.3);
}

class CardLayout {
  CardLayout._(this.kind, this.width, this.height, this._paint, this._lines);

  /// The layout of [item] (card JSON) at [width] page units. [files] gives
  /// stored file details and pictures; [scroll] is the CSV table offset.
  factory CardLayout(
    Map<String, Object?> item,
    double width,
    CardStyle style,
    AttachmentCache? files, {
    Offset scroll = Offset.zero,
  }) {
    final kind = item['kind'] as String? ?? '';
    final inner = math.max(width - 2 * _pad, 1.0);
    final lines = <TextPainter>[];
    TextPainter text(String value, TextStyle s, double max) {
      final p = TextPainter(
        text: TextSpan(text: value, style: s),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: math.max(max, 1));
      lines.add(p);
      return p;
    }

    final c = style.colors;
    void box(Canvas canvas, Rect r) {
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(_radius));
      canvas
        ..drawRRect(rr, Paint()..color = c.surface)
        ..drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = c.border,
        );
    }

    switch (kind) {
      case 'link_card' || 'website_card' || 'youtube_card':
        final url = item['url'] as String? ?? '';
        final title = (item['title'] as String?)?.trim();
        final site = kind == 'youtube_card'
            ? 'YouTube'
            : ((item['site_name'] as String?)?.trim().isNotEmpty ?? false)
            ? item['site_name'] as String
            : siteOf(url);
        final pictureId = item['preview_file_id'] as String?;
        final picture = kind == 'link_card' || pictureId == null
            ? null
            : files?.image(pictureId);
        final hasPicture = kind != 'link_card' && pictureId != null;
        final level = !hasPicture
            ? 0
            : width >= CardLevels.pictureLeft
            ? 2
            : width >= CardLevels.pictureTop
            ? 1
            : 0;
        final pictureSize = switch (level) {
          2 => const Size(
            CardLevels.sidePicture,
            CardLevels.sidePicture * 9 / 16,
          ),
          1 => Size(inner, inner * 9 / 16),
          _ => Size.zero,
        };
        final textWidth = level == 2 ? inner - pictureSize.width - _pad : inner;
        final t = text(
          title == null || title.isEmpty ? url : title,
          style.title,
          textWidth,
        );
        final description = kind == 'website_card'
            ? (item['description'] as String?)?.trim()
            : null;
        final d = description == null || description.isEmpty
            ? null
            : (TextPainter(
                text: TextSpan(text: description, style: style.secondary),
                textDirection: TextDirection.ltr,
                textScaler: TextScaler.noScaling,
                maxLines: 3,
                ellipsis: '…',
              )..layout(maxWidth: math.max(textWidth, 1)));
        if (d != null) lines.add(d);
        final s = text(site, style.secondary, textWidth);
        final textHeight =
            t.height + (d == null ? 0 : _gap + d.height) + _gap + s.height;
        final height = switch (level) {
          2 => _pad * 2 + math.max(textHeight, pictureSize.height),
          1 => _pad * 3 + pictureSize.height + textHeight,
          _ => _pad * 2 + textHeight,
        };
        return CardLayout._(kind, width, height, (canvas, r) {
          box(canvas, r);
          var x = r.left + _pad, y = r.top + _pad;
          if (level > 0) {
            final pr = Rect.fromLTWH(
              x,
              y,
              pictureSize.width,
              pictureSize.height,
            );
            _picture(canvas, pr, picture, c);
            if (level == 2) {
              x += pictureSize.width + _pad;
            } else {
              y += pictureSize.height + _pad;
            }
          }
          t.paint(canvas, Offset(x, y));
          y += t.height + _gap;
          if (d != null) {
            d.paint(canvas, Offset(x, y));
            y += d.height + _gap;
          }
          s.paint(canvas, Offset(x, y));
        }, lines);
      case 'file_card':
        final info = files?.info(item['file_id'] as String? ?? '');
        final name = info?.name ?? '';
        final iconSide = 24.0;
        final textWidth = inner - iconSide - _pad;
        final n = text(name, style.title, textWidth);
        final meta = info == null
            ? ''
            : '${fileTypeLabel(info.name, info.type)}, ${formatFileSize(info.size)}';
        final m = text(meta, style.secondary, textWidth);
        final height =
            _pad * 2 + math.max(n.height + _gap + m.height, iconSide);
        return CardLayout._(kind, width, height, (canvas, r) {
          box(canvas, r);
          _icon(
            canvas,
            AppIcons.file,
            Rect.fromLTWH(r.left + _pad, r.top + _pad, iconSide, iconSide),
            c.iconSecondary,
          );
          final x = r.left + _pad + iconSide + _pad;
          n.paint(canvas, Offset(x, r.top + _pad));
          m.paint(canvas, Offset(x, r.top + _pad + n.height + _gap));
        }, lines);
      case 'csv_table':
        final rows = files?.csv(item['file_id'] as String? ?? '');
        return CardLayout._(kind, width, null, (canvas, r) {
          box(canvas, r);
          if (rows == null || rows.isEmpty) {
            _icon(canvas, AppIcons.fileText, _centered(r, 24), c.iconSecondary);
            return;
          }
          _table(canvas, r.deflate(1), rows, style, scroll);
        }, lines);
      case 'pdf_preview':
        final fileId = item['file_id'] as String? ?? '';
        final info = files?.info(fileId);
        final pdf = files?.pdf(fileId);
        return CardLayout._(kind, width, null, (canvas, r) {
          // The page itself, with its name and page count.
          canvas.drawRect(r, Paint()..color = const Color(0xFFFFFFFF));
          canvas.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = c.border,
          );
          final page = style.secondary.copyWith(color: const Color(0xFF5B6170));
          final side = math.min(32.0, r.shortestSide / 3);
          _icon(
            canvas,
            AppIcons.fileText,
            Rect.fromLTWH(
              r.center.dx - side / 2,
              r.top + r.height / 3 - side,
              side,
              side,
            ),
            const Color(0xFF5B6170),
          );
          final label = TextPainter(
            text: TextSpan(
              text: [
                if (info != null) info.name,
                if (pdf != null) '${pdf.pages} p.',
              ].join('\n'),
              style: page,
            ),
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
            maxLines: 3,
            ellipsis: '…',
          )..layout(maxWidth: math.max(r.width - 2 * _pad, 1));
          label.paint(
            canvas,
            Offset(r.center.dx - label.width / 2, r.top + r.height / 3 + _gap),
          );
          label.dispose();
        }, lines);
      case 'image':
        final image = files?.image(item['file_id'] as String? ?? '');
        return CardLayout._(kind, width, null, (canvas, r) {
          _picture(canvas, r, image, c);
        }, lines);
      default:
        return CardLayout._(kind, width, null, box, lines);
    }
  }

  final String kind;
  final double width;

  /// The measured height of a card whose text wraps, or null for kinds
  /// whose height comes from their box (pictures, PDF, tables).
  final double? height;
  final void Function(Canvas canvas, Rect rect) _paint;
  final List<TextPainter> _lines;

  void paint(Canvas canvas, Rect rect) {
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(_radius)),
    );
    _paint(canvas, rect);
    canvas.restore();
  }

  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
  }
}

/// The stored height of a card whose text wraps at [width], measured as it
/// is drawn; null for the other kinds.
double? measureCard(
  Map<String, Object?> item,
  double width,
  CardStyle style,
  AttachmentCache? files,
) {
  if (!const {
    'link_card',
    'website_card',
    'youtube_card',
    'file_card',
  }.contains(item['kind'])) {
    return null;
  }
  final layout = CardLayout(item, width, style, files);
  final h = layout.height;
  layout.dispose();
  return h == null ? null : (h * 100).ceil() / 100;
}

Rect _centered(Rect r, double side) =>
    Rect.fromCenter(center: r.center, width: side, height: side);

void _icon(Canvas canvas, AppIconData icon, Rect r, Color color) {
  final paint = Paint()..color = color;
  canvas.save();
  canvas.translate(r.left, r.top);
  canvas.scale(r.width / 20);
  for (final p in icon.parsed) {
    canvas.drawPath(p, paint);
  }
  canvas.restore();
}

/// A picture in [r], keeping its shape (contained, centered); a quiet box
/// with a picture mark until it is read.
void _picture(Canvas canvas, Rect r, ui.Image? image, AppColors c) {
  final rr = RRect.fromRectAndRadius(r, const Radius.circular(6));
  canvas.drawRRect(rr, Paint()..color = c.subtle);
  if (image == null) {
    _icon(
      canvas,
      AppIcons.image,
      _centered(r, math.min(24, r.shortestSide * 0.6)),
      c.iconSecondary,
    );
    return;
  }
  final src = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  final fitted = applyBoxFit(BoxFit.contain, src.size, r.size);
  final dst = Alignment.center.inscribe(fitted.destination, r);
  canvas.save();
  canvas.clipRRect(rr);
  canvas.drawImageRect(
    image,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.restore();
}

/// The CSV rows in [r] from [scroll] (page units); the first row is the
/// header and stays on top.
void _table(
  Canvas canvas,
  Rect r,
  List<List<String>> rows,
  CardStyle style,
  Offset scroll,
) {
  const cellWidth = 120.0, rowHeight = 28.0, cellPad = 8.0;
  final c = style.colors;
  canvas.save();
  canvas.clipRect(r);
  final columns = rows.fold<int>(0, (n, row) => math.max(n, row.length));
  final line = Paint()
    ..color = c.border
    ..strokeWidth = 1;
  void row(List<String> cells, double y, bool header) {
    for (var col = 0; col < columns; col++) {
      final x = r.left + col * cellWidth - scroll.dx;
      if (x > r.right || x + cellWidth < r.left) continue;
      final value = col < cells.length ? cells[col] : '';
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: (header ? style.title : style.secondary).copyWith(
            fontSize: 13,
            color: c.text,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: cellWidth - 2 * cellPad);
      p.paint(canvas, Offset(x + cellPad, y + (rowHeight - p.height) / 2));
      p.dispose();
      canvas.drawLine(
        Offset(x + cellWidth, y),
        Offset(x + cellWidth, y + rowHeight),
        line,
      );
    }
    canvas.drawLine(
      Offset(r.left, y + rowHeight),
      Offset(r.right, y + rowHeight),
      line,
    );
  }

  final first = (scroll.dy / rowHeight).floor().clamp(0, rows.length);
  for (var i = math.max(first, 1); i < rows.length; i++) {
    final y = r.top + rowHeight + (i - 1) * rowHeight - scroll.dy;
    if (y > r.bottom) break;
    if (y + rowHeight < r.top + rowHeight) continue;
    row(rows[i], y, false);
  }
  canvas.drawRect(
    Rect.fromLTWH(r.left, r.top, r.width, rowHeight),
    Paint()..color = c.subtle,
  );
  row(rows.first, r.top, true);
  canvas.restore();
}

/// The largest table offset for [rows] in a box of [size].
Offset maxTableScroll(List<List<String>> rows, Size size) {
  const cellWidth = 120.0, rowHeight = 28.0;
  final columns = rows.fold<int>(0, (n, row) => math.max(n, row.length));
  return Offset(
    math.max(0, columns * cellWidth - size.width),
    math.max(0, rows.length * rowHeight - size.height),
  );
}
