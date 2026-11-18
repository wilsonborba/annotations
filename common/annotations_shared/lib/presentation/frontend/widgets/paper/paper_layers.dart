/// The painted layers of the paper canvas. Each layer repaints only for its
/// own inputs (annotations#26, point 5):
/// - [PaperLayerPainter]: desk, paper and background guides (view, page);
/// - [ContentLayerPainter]: the saved text, ink and blocks (view, document);
/// - [ActiveInkPainter]: the stroke being drawn (view, active stroke only);
/// - [FrameLayerPainter]: hover and selection borders (view, hover,
///   selection, pointer device).
///
/// Content is drawn from the stored values in page units; the canvas is
/// scaled by the view zoom, so a screen size never changes a position.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../../core/paper_settings.dart';
import '../../../../domain/models/ink.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/services/ink_outline.dart';
import '../../../../domain/services/object_selection.dart';
import '../../../../domain/services/paper_page.dart';
import '../../components/icons.dart';
import '../../components/paper_guides.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';

/// Paint calls per layer, for the repaint tests and the performance record.
@visibleForTesting
final paperPaintCounts = <String, int>{};

void _count(String layer) =>
    paperPaintCounts[layer] = (paperPaintCounts[layer] ?? 0) + 1;

void _applyView(Canvas canvas, PaperView view) {
  canvas.scale(view.zoom);
  canvas.translate(-view.scroll.dx, -view.scroll.dy);
}

// Paper ------------------------------------------------------------------

class PaperLayerPainter extends CustomPainter {
  PaperLayerPainter({
    required this.view,
    required this.guides,
    required this.width,
    required this.height,
    required this.colors,
    this.settings = const PaperSettings(),
  });

  final PaperView view;
  final PaperGuides guides;
  final double width, height;
  final PaperColors colors;
  final PaperSettings settings;

  @override
  void paint(Canvas canvas, Size size) {
    _count('paper');
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.desk);
    canvas.save();
    _applyView(canvas, view);
    final paper = Rect.fromLTWH(0, 0, width, height);
    canvas.drawRect(paper, Paint()..color = colors.paper);
    final visible = view.visiblePage.intersect(paper);
    if (!visible.isEmpty) {
      canvas.clipRect(paper);
      paintGuides(
        canvas,
        guides,
        PaperPage(settings: settings).lines(
          guides,
          width: width,
          left: visible.left,
          top: visible.top,
          right: visible.right,
          bottom: visible.bottom,
        ),
        zoom: view.zoom,
        clip: visible,
        color: colors.guide,
        settings: settings,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PaperLayerPainter old) =>
      old.view != view ||
      old.guides != guides ||
      old.width != width ||
      old.height != height ||
      old.colors.paper != colors.paper ||
      old.colors.guide != colors.guide;
}

// Content ----------------------------------------------------------------

/// The drawing of one item, prepared once per stored state of the item.
final class _Drawing {
  _Drawing(this.json, this.bounds, this.draw, [this.dispose]);
  final Map<String, Object?> json;
  final void Function()? dispose;

  /// The visible area in page units, for culling and borders.
  final Rect bounds;
  final void Function(Canvas canvas) draw;
}

/// Prepared drawings of the items of a document. An item whose stored JSON
/// did not change keeps its paths and text layout, so an edit prepares only
/// the changed items.
class ContentCache {
  ContentCache({required this.textStyle});

  final TextStyle textStyle;
  final _byId = <String, _Drawing>{};
  var _order = <_Drawing>[];
  NoteDocument? _document;
  AppColors? _colors;

  /// Prepares [document]; cheap when nothing changed.
  void update(NoteDocument document, AppColors colors) {
    if (identical(document, _document) && identical(colors, _colors)) return;
    if (!identical(colors, _colors)) _clear();
    _document = document;
    _colors = colors;
    final items = document is PaperDocument
        ? document.items
        : const <DocumentItem>[];
    final next = <String, _Drawing>{};
    final order = <_Drawing>[];
    for (final item in items) {
      final id = item.id;
      if (id == null) continue;
      final json = item.toJson();
      var d = _byId[id];
      if (d == null || !_sameJson(d.json, json)) {
        d?.dispose?.call();
        d = _prepare(item, json, colors);
      }
      if (d == null) continue;
      next[id] = d;
      order.add(d);
    }
    for (final MapEntry(:key, :value) in _byId.entries) {
      if (!identical(next[key], value)) value.dispose?.call();
    }
    _byId
      ..clear()
      ..addAll(next);
    _order = order;
  }

  void _clear() {
    for (final d in _byId.values) {
      d.dispose?.call();
    }
    _byId.clear();
  }

  /// Releases the text layouts.
  void dispose() {
    _clear();
    _order = [];
  }

  /// The drawn area of [id] in page units, or null.
  Rect? boundsOf(String id) => _byId[id]?.bounds;

  int get length => _order.length;

  /// Draws every item that meets [visible] (page units), in item order.
  void paint(Canvas canvas, Rect visible) {
    for (final d in _order) {
      if (d.bounds.overlaps(visible)) d.draw(canvas);
    }
  }

  _Drawing? _prepare(
    DocumentItem item,
    Map<String, Object?> json,
    AppColors colors,
  ) {
    switch (item) {
      case StrokeItem():
        final outline = strokeOutline(item);
        if (outline == null) return null;
        final path = _path(outline.pieces);
        final paint = Paint()..color = Color(outline.argb);
        return _Drawing(
          json,
          path.getBounds(),
          (canvas) => canvas.drawPath(path, paint),
        );
      case ShapeItem():
        final outline = shapeOutline(item);
        if (outline == null) return null;
        final line = _path(outline.line.pieces);
        final linePaint = Paint()..color = Color(outline.line.argb);
        final fill = outline.fill == null
            ? null
            : (Path()..addPolygon([
                for (final v in outline.fill!) Offset(v.x, v.y),
              ], true));
        final fillPaint = outline.fillArgb == null
            ? null
            : (Paint()..color = Color(outline.fillArgb!));
        var bounds = line.getBounds();
        if (fill != null) bounds = bounds.expandToInclude(fill.getBounds());
        return _Drawing(json, bounds, (canvas) {
          if (fill != null && fillPaint != null) {
            canvas.drawPath(fill, fillPaint);
          }
          canvas.drawPath(line, linePaint);
        });
      case TextItem(:final bounds?, :final spans):
        final rect = _rect(bounds);
        final lines = _textLines(spans, rect.width, colors);
        return _Drawing(
          json,
          rect,
          (canvas) {
            var y = rect.top;
            for (final line in lines) {
              line.paint(canvas, Offset(rect.left, y));
              y += line.height;
            }
          },
          () {
            for (final line in lines) {
              line.dispose();
            }
          },
        );
      case StructuredItem(:final bounds?):
        // A neutral block until its card arrives (annotations#34).
        final rect = _rect(bounds);
        final icon = _blockIcon(item);
        final fill = Paint()..color = colors.subtle;
        final mark = Paint()..color = colors.iconSecondary;
        return _Drawing(json, rect, (canvas) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(8)),
            fill,
          );
          final side = 24.0.clamp(0.0, rect.shortestSide * 0.6);
          canvas.save();
          canvas.translate(
            rect.center.dx - side / 2,
            rect.center.dy - side / 2,
          );
          canvas.scale(side / 20);
          for (final p in icon.parsed) {
            canvas.drawPath(p, mark);
          }
          canvas.restore();
        });
      default:
        return null;
    }
  }

  /// The text of a text item, one painter per line, the way the text engine
  /// measures it (one paragraph style with its strut on every line).
  List<TextPainter> _textLines(
    List<TextSpanValue> spans,
    double width,
    AppColors colors,
  ) {
    // A span without a stored color takes the text color of the mode; a
    // stored color is drawn as it is in both modes (B4.4).
    final base = textStyle.copyWith(color: colors.text);
    final lines = <List<InlineSpan>>[[]];
    for (final span in spans) {
      final parts = span.text.split('\n');
      for (final (i, part) in parts.indexed) {
        if (i > 0) lines.add([]);
        if (part.isNotEmpty) {
          lines.last.add(TextSpan(text: part, style: _inline(span)));
        }
      }
    }
    return [
      for (final line in lines)
        TextPainter(
          text: TextSpan(style: base, children: line),
          textDirection: TextDirection.ltr,
          strutStyle: StrutStyle.fromTextStyle(textStyle),
          textScaler: TextScaler.noScaling,
        )..layout(maxWidth: width),
    ];
  }

  TextStyle _inline(TextSpanValue span) {
    var style = const TextStyle();
    if (span.bold == true) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    if (span.italic == true) {
      style = style.merge(const TextStyle(fontStyle: FontStyle.italic));
    }
    if (span.strikethrough == true) {
      style = style.merge(
        const TextStyle(decoration: TextDecoration.lineThrough),
      );
    }
    if (span.size case final size?) {
      style = style.merge(TextStyle(fontSize: size.toDouble()));
    }
    if (span.color case final color?) {
      style = style.merge(TextStyle(color: Color(colorArgb(color, 1))));
    }
    return style;
  }
}

Rect _rect(ItemBounds b) => Rect.fromLTWH(
  b.x.toDouble(),
  b.y.toDouble(),
  b.width.toDouble(),
  b.height.toDouble(),
);

Path _path(List<List<InkVec>> pieces) {
  final path = Path()..fillType = ui.PathFillType.nonZero;
  for (final piece in pieces) {
    path.addPolygon([for (final v in piece) Offset(v.x, v.y)], true);
  }
  return path;
}

AppIconData _blockIcon(DocumentItem item) => switch (item) {
  ImageItem() => AppIcons.image,
  YoutubeCard() => AppIcons.video,
  LinkCard() => AppIcons.link,
  FileCard() => AppIcons.file,
  _ => AppIcons.fileText,
};

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_sameJson(e.value, b[e.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class ContentLayerPainter extends CustomPainter {
  ContentLayerPainter({
    required this.view,
    required this.cache,
    required this.document,
  });

  final PaperView view;
  final ContentCache cache;

  /// The document state that [cache] prepared; a new state repaints.
  final NoteDocument document;

  @override
  void paint(Canvas canvas, Size size) {
    _count('content');
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _applyView(canvas, view);
    cache.paint(canvas, view.visiblePage);
    canvas.restore();
  }

  @override
  bool shouldRepaint(ContentLayerPainter old) =>
      old.view != view || !identical(old.document, document);
}

// Active stroke ----------------------------------------------------------

/// The stroke being drawn. It listens to its own notifier, so a new sample
/// repaints this layer and nothing else.
class ActiveInkPainter extends CustomPainter {
  ActiveInkPainter({required this.view, required this.ink})
    : super(repaint: ink);

  final PaperView view;
  final ValueListenable<InkOutline?> ink;

  @override
  void paint(Canvas canvas, Size size) {
    _count('active');
    final outline = ink.value;
    if (outline == null) return;
    canvas.save();
    _applyView(canvas, view);
    canvas.drawPath(
      _path(outline.pieces),
      Paint()..color = Color(outline.argb),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ActiveInkPainter old) =>
      old.view != view || old.ink != ink;
}

// Borders ----------------------------------------------------------------

/// Borders appear only for the hovered unit (mouse or pen) and the selected
/// units. Normal reading and writing show no border (owner basis B1-B2).
class FrameLayerPainter extends CustomPainter {
  FrameLayerPainter({
    required this.view,
    required this.hover,
    required this.selection,
    required this.pointer,
    required this.handler,
    required this.cache,
    required this.document,
    required this.colors,
    this.settings = const PaperSettings(),
  }) : super(repaint: Listenable.merge([hover, selection, pointer]));

  /// The document state of [cache]; a new state moves the borders.
  final NoteDocument document;

  final PaperView view;
  final ValueListenable<String?> hover;
  final ValueListenable<ObjectSelection> selection;
  final ValueListenable<PointerDeviceKind> pointer;
  final PaperHandler handler;
  final ContentCache cache;
  final AppColors colors;
  final PaperSettings settings;

  /// The screen rectangle of the border around the unit [id].
  Rect? frameOf(String id) {
    final layout = handler.layout;
    if (layout == null) return null;
    Rect? area;
    for (final m in layout.withDescendants(id)) {
      final b = cache.boundsOf(m);
      if (b != null) area = area == null ? b : area.expandToInclude(b);
    }
    if (area == null) return null;
    return view.rectToScreen(area).inflate(settings.framePadding);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _count('frame');
    final selected = selection.value;
    final hovered = hover.value;
    if (hovered != null && !selected.contains(hovered)) {
      final r = frameOf(hovered);
      if (r != null) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(r, const Radius.circular(4)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colors.control,
        );
      }
    }
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = colors.selectionOutline;
    final touch = pointer.value == PointerDeviceKind.touch;
    final side = touch ? settings.touchHandle : settings.mouseHandle;
    for (final id in selected.ids) {
      final r = frameOf(id);
      if (r == null) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(4)),
        border,
      );
      // Handles only for one selected unit: resize acts on one object.
      if (selected.ids.length != 1) continue;
      for (final corner in [
        r.topLeft,
        r.topRight,
        r.bottomLeft,
        r.bottomRight,
      ]) {
        final h = Rect.fromCenter(center: corner, width: side, height: side);
        final rr = RRect.fromRectAndRadius(h, const Radius.circular(2));
        canvas.drawRRect(rr, Paint()..color = colors.selection);
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colors.selectionOutline,
        );
      }
    }
  }

  @override
  bool shouldRepaint(FrameLayerPainter old) =>
      old.view != view ||
      old.hover != hover ||
      old.selection != selection ||
      old.cache != cache ||
      !identical(old.document, document) ||
      old.colors != colors;
}
