/// The drawing tools of Draw mode and their remembered settings (B6.1, B6.2,
/// B6.4): the four pens and the shapes.
///
/// Each tool keeps its own settings. Changing a setting changes only the
/// settings of new strokes; a stored stroke never follows them. With selected
/// ink, a setting change goes to [InkEditing.restyleInk] instead and the tool
/// settings stay (B6.2).
library;

import 'dart:math' as math;

import '../../core/draw_settings.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'object_selection.dart';

/// A tool of Draw mode: the four pens (B6.1) and the shapes (B6.4).
enum DrawTool {
  round,
  flat,
  brush,
  highlighter,
  shapes,
  eraser,
  select;

  /// The pen of this tool, or null for the shapes, the eraser and select.
  InkTool? get pen => InkTool.parse(name);

  static DrawTool? parse(Object? value) {
    for (final tool in values) {
      if (tool.name == value) return tool;
    }
    return null;
  }
}

/// The geometric shapes (B6.4).
enum ShapeKind {
  circle,
  triangle,
  rectangle;

  static ShapeKind? parse(Object? value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// The settings of the shape tool for new shapes.
final class ShapeSettings {
  const ShapeSettings({
    required this.kind,
    required this.lineWidth,
    required this.color,
    this.opacity = 1,
  });

  final ShapeKind kind;

  /// Logical page units.
  final num lineWidth;

  /// #RRGGBBAA.
  final String color;
  final num opacity;

  ShapeStyle get style =>
      ShapeStyle(color: color, lineWidth: lineWidth, opacity: opacity);

  ShapeSettings copyWith({
    ShapeKind? kind,
    num? lineWidth,
    String? color,
    num? opacity,
  }) => ShapeSettings(
    kind: kind ?? this.kind,
    lineWidth: lineWidth ?? this.lineWidth,
    color: color ?? this.color,
    opacity: opacity ?? this.opacity,
  );
}

/// One setting change of a tool panel.
final class InkStyleChange {
  const InkStyleChange({this.width, this.color, this.opacity, this.tipAngle});

  final num? width;
  final String? color;
  final num? opacity;
  final num? tipAngle;
}

/// The values that a tool panel shows: the tool settings, or the style of the
/// first selected ink item.
final class InkStyle {
  const InkStyle({
    required this.width,
    required this.color,
    required this.opacity,
    this.tipAngle,
  });

  final num width;
  final String color;
  final num opacity;
  final num? tipAngle;

  InkStyle apply(InkStyleChange c) => InkStyle(
    width: c.width ?? width,
    color: c.color ?? color,
    opacity: c.opacity ?? opacity,
    tipAngle: c.tipAngle ?? tipAngle,
  );
}

/// The remembered settings of the normal eraser (B2.6): its mode and the
/// circle radius in page units. Delete-anything mode is never remembered: it
/// turns off when the user leaves the eraser.
final class EraserSettings {
  const EraserSettings({
    this.mode = EraserMode.partialStroke,
    required this.radius,
  });
  final EraserMode mode;
  final num radius;

  EraserSettings copyWith({EraserMode? mode, num? radius}) =>
      EraserSettings(mode: mode ?? this.mode, radius: radius ?? this.radius);
}

/// The active tool and the remembered settings of every tool. Immutable.
final class DrawTools {
  const DrawTools({
    required this.active,
    required this.pens,
    required this.shape,
    required this.eraser,
  });

  /// The first state: the round pen is the selected tool (B6.1).
  factory DrawTools.initial([DrawSettings s = const DrawSettings()]) =>
      DrawTools(
        active: DrawTool.round,
        pens: {
          InkTool.round: BrushSettings(
            tool: InkTool.round,
            width: s.roundWidth,
            color: s.penColor,
          ),
          InkTool.flat: BrushSettings(
            tool: InkTool.flat,
            width: s.flatWidth,
            color: s.penColor,
            tipAngle: s.flatTipAngle,
          ),
          InkTool.brush: BrushSettings(
            tool: InkTool.brush,
            width: s.brushWidth,
            color: s.penColor,
          ),
          InkTool.highlighter: BrushSettings(
            tool: InkTool.highlighter,
            width: s.highlighterWidth,
            color: s.highlighterColor,
            opacity: s.highlighterOpacity,
          ),
        },
        shape: ShapeSettings(
          kind: ShapeKind.rectangle,
          lineWidth: s.shapeLineWidth,
          color: s.penColor,
        ),
        eraser: EraserSettings(radius: s.eraserRadius),
      );

  final DrawTool active;
  final Map<InkTool, BrushSettings> pens;
  final ShapeSettings shape;
  final EraserSettings eraser;

  BrushSettings pen(InkTool tool) => pens[tool]!;

  /// The settings of [tool] as panel values.
  InkStyle styleOf(DrawTool tool) {
    final pen = tool.pen;
    if (pen == null) {
      return InkStyle(
        width: shape.lineWidth,
        color: shape.color,
        opacity: shape.opacity,
      );
    }
    final b = this.pen(pen);
    return InkStyle(
      width: b.width,
      color: b.color,
      opacity: b.opacity,
      tipAngle: b.tipAngle,
    );
  }

  DrawTools withActive(DrawTool tool) =>
      DrawTools(active: tool, pens: pens, shape: shape, eraser: eraser);

  DrawTools withShapeKind(ShapeKind kind) => DrawTools(
    active: active,
    pens: pens,
    shape: shape.copyWith(kind: kind),
    eraser: eraser,
  );

  DrawTools withEraser(EraserSettings value) =>
      DrawTools(active: active, pens: pens, shape: shape, eraser: value);

  /// The settings of [tool] with [change]. Other tools keep theirs.
  DrawTools changed(DrawTool tool, InkStyleChange change) {
    final pen = tool.pen;
    if (tool == DrawTool.eraser || tool == DrawTool.select) return this;
    if (pen == null) {
      return DrawTools(
        active: active,
        pens: pens,
        eraser: eraser,
        shape: shape.copyWith(
          lineWidth: change.width,
          color: change.color,
          opacity: change.opacity,
        ),
      );
    }
    final b = this.pen(pen);
    return DrawTools(
      active: active,
      pens: {
        ...pens,
        pen: BrushSettings(
          tool: pen,
          width: change.width ?? b.width,
          color: change.color ?? b.color,
          opacity: change.opacity ?? b.opacity,
          tipAngle: pen == InkTool.flat
              ? (change.tipAngle ?? b.tipAngle)
              : null,
        ),
      },
      shape: shape,
      eraser: eraser,
    );
  }

  /// The device value (not note data).
  Map<String, Object?> toJson() => {
    'active': active.name,
    for (final MapEntry(key: tool, value: b) in pens.entries)
      tool.name: {
        'width': b.width,
        'color': b.color,
        'opacity': b.opacity,
        if (b.tipAngle != null) 'tip_angle': b.tipAngle,
      },
    'shapes': {
      'shape': shape.kind.name,
      'width': shape.lineWidth,
      'color': shape.color,
      'opacity': shape.opacity,
    },
    'eraser': {'mode': eraser.mode.name, 'radius': eraser.radius},
  };

  /// Reads a device value. A missing or invalid value keeps the first
  /// setting of that tool, so a damaged value never blocks drawing.
  factory DrawTools.fromJson(
    Object? json, [
    DrawSettings s = const DrawSettings(),
  ]) {
    var tools = DrawTools.initial(s);
    if (json is! Map) return tools;
    InkStyleChange read(Object? v) {
      if (v is! Map) return const InkStyleChange();
      final width = v['width'], opacity = v['opacity'], angle = v['tip_angle'];
      final color = v['color'];
      return InkStyleChange(
        width: width is num && width > 0 ? width : null,
        color: color is String && isInkColor(color) ? color : null,
        opacity: opacity is num && opacity > 0 && opacity <= 1 ? opacity : null,
        tipAngle: angle is num && angle.abs() <= math.pi ? angle : null,
      );
    }

    for (final tool in DrawTool.values) {
      final key = tool.name;
      tools = tools.changed(tool, read(json[key]));
    }
    final eraser = json['eraser'];
    if (eraser is Map) {
      final radius = eraser['radius'];
      final mode = EraserMode.values
          .where((m) => m.name == eraser['mode'])
          .firstOrNull;
      tools = tools.withEraser(
        tools.eraser.copyWith(
          mode: mode,
          radius:
              radius is num &&
                  radius >= s.minEraserRadius &&
                  radius <= s.maxEraserRadius
              ? radius
              : null,
        ),
      );
    }
    final shapes = json['shapes'];
    if (shapes is Map) {
      final kind = ShapeKind.parse(shapes['shape']);
      if (kind != null) tools = tools.withShapeKind(kind);
    }
    final active = DrawTool.parse(json['active']);
    return active == null ? tools : tools.withActive(active);
  }
}

final _inkColor = RegExp(r'^#[0-9A-Fa-f]{8}$');

/// Whether [value] is a stored color: #RRGGBBAA.
bool isInkColor(String value) => _inkColor.hasMatch(value);

/// The ink items that a setting change reaches: every stroke and shape of
/// the selected units, members of selected groups included (B6.2). Text and
/// blocks in the selection are not changed.
List<String> selectedInk(DocumentLayout layout, ObjectSelection selection) => [
  for (final unit in selection.inDocumentOrder(layout))
    for (final id in layout.withDescendants(unit))
      if (layout.kindOf(id) == 'stroke' || layout.kindOf(id) == 'shape') id,
];

/// The style of the ink item [id] as panel values, or null.
InkStyle? inkStyleOf(DocumentLayout layout, String id) {
  final it = layout.itemJson(id);
  if (it == null) return null;
  final width = it[it['kind'] == 'stroke' ? 'width' : 'line_width'];
  final color = it['color'], opacity = it['opacity'];
  if (width is! num || color is! String || opacity is! num) return null;
  return InkStyle(
    width: width,
    color: color,
    opacity: opacity,
    tipAngle: it['tip_angle'] as num?,
  );
}

/// A geometric shape from a drag between [a] and [b] (page units): the
/// rectangle of the drag, the circle inside it, or the triangle with its top
/// point at the middle of the upper side. Null when the drag is smaller than
/// [minSize] on both sides.
JsonObject? shapeFromDrag(
  String id,
  ShapeKind kind,
  InkVec a,
  InkVec b,
  ShapeStyle style, {
  num minSize = 4,
}) {
  final left = math.min(a.x, b.x), top = math.min(a.y, b.y);
  final w = (a.x - b.x).abs(), h = (a.y - b.y).abs();
  if (w < minSize && h < minSize) return null;
  switch (kind) {
    case ShapeKind.rectangle:
      return InkShapes.rectangle(id, InkVec(left, top), w, h, style);
    case ShapeKind.circle:
      final r = math.max(w, h) / 2;
      // The circle follows the drag from its start corner, so it grows like
      // a square drag in the same direction.
      final dx = b.x >= a.x ? r : -r, dy = b.y >= a.y ? r : -r;
      return InkShapes.circle(id, InkVec(a.x + dx, a.y + dy), r, style);
    case ShapeKind.triangle:
      return InkShapes.triangle(id, [
        InkVec(left + w / 2, top),
        InkVec(left + w, top + h),
        InkVec(left, top + h),
      ], style);
  }
}

/// Whether [id] is a circle, triangle or rectangle that Edit as path can
/// convert (B6.4).
bool isGeometricShape(DocumentLayout layout, String id) {
  final it = layout.itemJson(id);
  return it != null &&
      it['kind'] == 'shape' &&
      const ['circle', 'triangle', 'rectangle'].contains(it['shape']);
}

/// The stored document is a paper document with free ink.
bool canDraw(NoteDocument document) => document is PaperDocument;
