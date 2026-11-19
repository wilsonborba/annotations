/// The controls of Type and Draw modes (annotations#28): the mode switch,
/// the settings panel of a drawing tool with its mark preview, and the
/// color choices with the custom picker (B5, B6.2, B6.4).
///
/// They show values and report changes; the draw handler decides what a
/// change does (the tool settings, or only the selected ink).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/draw_settings.dart';
import '../../../domain/models/ink.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/draw_tools.dart';
import '../../../domain/services/editor_rules.dart'
    show EraserMode, ShapeStyle, StrokeCapture;
import '../../../domain/services/ink_outline.dart';
import '../../../domain/services/object_selection.dart';
import 'controls.dart';
import 'icons.dart';
import 'paper_controls.dart' show SettingSlider;
import 'paper_guides.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

String drawToolLabel(BuildContext context, DrawTool tool) =>
    context.tr(switch (tool) {
      DrawTool.round => 'penRound',
      DrawTool.flat => 'penFlat',
      DrawTool.brush => 'penBrush',
      DrawTool.highlighter => 'highlighter',
      DrawTool.shapes => 'shapes',
      DrawTool.eraser => 'eraser',
      DrawTool.select => 'selectTool',
    });

AppIconData drawToolIcon(DrawTool tool) => switch (tool) {
  DrawTool.round => AppIcons.roundPen,
  DrawTool.flat => AppIcons.flatPen,
  DrawTool.brush => AppIcons.brushPen,
  DrawTool.highlighter => AppIcons.highlighter,
  DrawTool.shapes => AppIcons.shapes,
  DrawTool.eraser => AppIcons.eraser,
  DrawTool.select => AppIcons.select,
};

String shapeLabel(BuildContext context, ShapeKind kind) =>
    context.tr(switch (kind) {
      ShapeKind.circle => 'shapeCircle',
      ShapeKind.triangle => 'shapeTriangle',
      ShapeKind.rectangle => 'shapeRectangle',
    });

AppIconData shapeIcon(ShapeKind kind) => switch (kind) {
  ShapeKind.circle => AppIcons.circle,
  ShapeKind.triangle => AppIcons.triangle,
  ShapeKind.rectangle => AppIcons.rectangle,
};

/// The display color of a stored #RRGGBBAA value.
Color inkColor(String value) => Color(colorArgb(value, 1));

/// The stored #RRGGBBAA value of an opaque [color].
String storedColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}FF';
}

BoxDecoration _panel(AppColors c) => BoxDecoration(
  color: c.surface,
  borderRadius: BorderRadius.circular(appPanelRadius),
  border: Border.all(color: c.border),
);

// Mode switch -------------------------------------------------------------

/// The clearly marked Type and Draw switch (B5). It stays visible while
/// editing; the active mode has the green selection fill with dark text.
class ModeSwitch extends StatelessWidget {
  final SelectionTool mode;
  final ValueChanged<SelectionTool> onChanged;

  /// Vertical in a toolbar docked at the left or right; [compact] shows the
  /// icons only, with the names as tooltips and accessible names.
  final Axis axis;
  final bool compact;
  const ModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
    this.axis = Axis.horizontal,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      container: true,
      label: context.tr('editMode'),
      child: Container(
        key: const Key('mode-switch'),
        padding: const EdgeInsets.all(2),
        decoration: _panel(c),
        child: Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Segment(
              key: const Key('mode-type'),
              icon: AppIcons.type,
              label: context.tr('modeType'),
              selected: mode == SelectionTool.type,
              compact: compact,
              onTap: () => onChanged(SelectionTool.type),
            ),
            const SizedBox(width: 2, height: 2),
            _Segment(
              key: const Key('mode-draw'),
              icon: AppIcons.drawMode,
              label: context.tr('modeDraw'),
              selected: mode == SelectionTool.draw,
              compact: compact,
              onTap: () => onChanged(SelectionTool.draw),
            ),
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final AppIconData icon;
  final String label;
  final bool selected, compact;
  final VoidCallback onTap;
  const _Segment({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final color = selected ? c.onSelection : c.text;
    final segment = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: TextButton(
        onPressed: onTap,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          fixedSize: WidgetStatePropertyAll(
            compact ? const Size.square(36) : const Size.fromHeight(36),
          ),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
          ),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => selected
                ? c.selection
                : s.contains(WidgetState.pressed)
                ? c.pressed
                : s.contains(WidgetState.hovered)
                ? c.subtle
                : Colors.transparent,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(appRadius),
              side: selected
                  ? BorderSide(color: c.selectionOutline)
                  : BorderSide.none,
            ),
          ),
        ),
        child: compact
            ? AppIcon(icon, size: 18, color: color)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(icon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: text.labelLarge!.copyWith(color: color)),
                ],
              ),
      ),
    );
    return compact ? AppTooltip(message: label, child: segment) : segment;
  }
}

// Tool settings -----------------------------------------------------------

/// The settings of a drawing tool (B6.2): a small mark preview, width,
/// opacity, the tip angle of the flat pen, and the colors. The shapes add
/// the shape choice and, for one selected shape, Edit as path (B6.4).
///
/// A slider reports `done: false` while it moves and `done: true` once at
/// its end, so one drag is one change.
class ToolSettingsPanel extends StatefulWidget {
  final DrawTool tool;
  final InkStyle style;

  /// True when the values belong to the selected ink.
  final bool selection;
  final bool showsTipAngle;
  final num maxWidth;
  final ShapeKind? shape;
  final ValueChanged<ShapeKind>? onShape;
  final void Function(InkStyleChange change, bool done) onChange;

  /// Edit as path; null hides it (no single geometric shape selected).
  final VoidCallback? onEditAsPath;

  /// Apply pen style to the selected strokes; null hides it (no stroke
  /// selected, or the tool is not a pen).
  final VoidCallback? onApplyStyle;
  final DrawSettings settings;
  const ToolSettingsPanel({
    super.key,
    required this.tool,
    required this.style,
    required this.onChange,
    this.selection = false,
    this.showsTipAngle = false,
    this.maxWidth = 40,
    this.shape,
    this.onShape,
    this.onEditAsPath,
    this.onApplyStyle,
    this.settings = const DrawSettings(),
  });

  @override
  State<ToolSettingsPanel> createState() => _ToolSettingsPanelState();
}

class _ToolSettingsPanelState extends State<ToolSettingsPanel> {
  bool _custom = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final s = w.settings;
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final width = w.style.width.toDouble().clamp(
      s.minWidth.toDouble(),
      w.maxWidth.toDouble(),
    );
    final opacity = w.style.opacity.toDouble().clamp(
      s.minOpacity.toDouble(),
      1.0,
    );
    final degrees = (((w.style.tipAngle ?? 0) * 180 / math.pi).round() % 180)
        .toDouble();
    void change(InkStyleChange value, bool done) => w.onChange(value, done);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        key: const Key('draw-settings'),
        width: 296,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              w.selection
                  ? context.tr('selectedInk')
                  : drawToolLabel(context, w.tool),
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            Semantics(
              label: context.tr('markPreview'),
              image: true,
              child: Container(
                key: const Key('draw-preview'),
                height: 64,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: PaperColors.of(c).paper,
                  borderRadius: BorderRadius.circular(appRadius),
                  border: Border.all(color: c.border),
                ),
                child: CustomPaint(
                  painter: MarkPreviewPainter(
                    tool: w.tool,
                    style: w.style,
                    shape: w.shape,
                  ),
                ),
              ),
            ),
            if (w.shape != null && w.onShape != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  for (final kind in ShapeKind.values)
                    AppIconButton(
                      key: Key('shape-${kind.name}'),
                      icon: shapeIcon(kind),
                      label: shapeLabel(context, kind),
                      selected: kind == w.shape,
                      onPressed: () => w.onShape!(kind),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            SettingSlider(
              key: const Key('draw-width'),
              label: context.tr('inkWidth'),
              value: width,
              display: '${width.round()}',
              min: s.minWidth.toDouble(),
              max: w.maxWidth.toDouble(),
              divisions: (w.maxWidth - s.minWidth).round(),
              onChanged: (v) => change(InkStyleChange(width: v.round()), false),
              onEnd: (v) => change(InkStyleChange(width: v.round()), true),
            ),
            SettingSlider(
              key: const Key('draw-opacity'),
              label: context.tr('inkOpacity'),
              value: opacity,
              display: '${(opacity * 100).round()}%',
              min: s.minOpacity.toDouble(),
              max: 1,
              divisions: ((1 - s.minOpacity) * 20).round(),
              onChanged: (v) => change(
                InkStyleChange(opacity: (v * 100).round() / 100),
                false,
              ),
              onEnd: (v) => change(
                InkStyleChange(opacity: (v * 100).round() / 100),
                true,
              ),
            ),
            if (w.showsTipAngle)
              SettingSlider(
                key: const Key('draw-tip-angle'),
                label: context.tr('tipAngle'),
                value: degrees,
                display: '${degrees.round()}°',
                min: 0,
                max: 175,
                divisions: 35,
                onChanged: (v) =>
                    change(InkStyleChange(tipAngle: _radians(v)), false),
                onEnd: (v) =>
                    change(InkStyleChange(tipAngle: _radians(v)), true),
              ),
            const SizedBox(height: 4),
            Text(context.tr('inkColor'), style: text.labelMedium),
            const SizedBox(height: 6),
            ColorChoices(
              color: w.style.color,
              colors: s.colors,
              customOpen: _custom,
              onColor: (v) => change(InkStyleChange(color: v), true),
              onCustom: () => setState(() => _custom = !_custom),
            ),
            if (_custom) ...[
              const SizedBox(height: 8),
              CustomColorPicker(
                color: w.style.color,
                onChanged: (v, done) => change(InkStyleChange(color: v), done),
              ),
            ],
            if (w.onApplyStyle != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton.subtle(
                  key: const Key('apply-pen-style'),
                  label: context.tr(switch (w.tool) {
                    DrawTool.round => 'applyPenRound',
                    DrawTool.flat => 'applyPenFlat',
                    DrawTool.brush => 'applyPenBrush',
                    _ => 'applyHighlighter',
                  }),
                  icon: drawToolIcon(w.tool),
                  onPressed: w.onApplyStyle,
                ),
              ),
            ],
            if (w.onEditAsPath != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton.subtle(
                  key: const Key('edit-as-path'),
                  label: context.tr('editAsPath'),
                  icon: AppIcons.path,
                  onPressed: w.onEditAsPath,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Degrees from the control to a stored angle in radians (2 decimals).
  static num _radians(double degrees) =>
      (degrees * math.pi / 180 * 100).round() / 100;
}

// Colors ------------------------------------------------------------------

/// The fixed colors and the custom picker button (B6.2). The current color
/// has the green selection fill around its swatch; a color that is not one
/// of the fixed colors selects the custom button.
class ColorChoices extends StatelessWidget {
  final String color;
  final List<(String, String)> colors;
  final bool customOpen;
  final ValueChanged<String> onColor;
  final VoidCallback onCustom;
  const ColorChoices({
    super.key,
    required this.color,
    required this.colors,
    required this.onColor,
    required this.onCustom,
    this.customOpen = false,
  });

  @override
  Widget build(BuildContext context) {
    final current = color.toUpperCase();
    final fixed = colors.any((e) => e.$2.toUpperCase() == current);
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final (name, value) in colors)
          _Swatch(
            key: Key('ink-color-$name'),
            label: context.tr(name),
            color: inkColor(value),
            selected: value.toUpperCase() == current,
            onTap: () => onColor(value),
          ),
        _Swatch(
          key: const Key('ink-color-custom'),
          label: context.tr('customColor'),
          color: fixed ? null : inkColor(color),
          selected: !fixed || customOpen,
          onTap: onCustom,
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final String label;

  /// Null: the custom button without a custom color yet (a plus icon).
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final button = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: TextButton(
        onPressed: onTap,
        style: ButtonStyle(
          fixedSize: const WidgetStatePropertyAll(Size.square(34)),
          minimumSize: const WidgetStatePropertyAll(Size.square(34)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => selected
                ? c.selection
                : s.contains(WidgetState.hovered)
                ? c.subtle
                : Colors.transparent,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(appRadius),
              side: selected
                  ? BorderSide(color: c.selectionOutline)
                  : BorderSide.none,
            ),
          ),
        ),
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color ?? c.surface,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: c.control),
          ),
          child: color == null
              ? AppIcon(AppIcons.add, size: 16, color: c.icon)
              : null,
        ),
      ),
    );
    return Tooltip(message: label, excludeFromSemantics: true, child: button);
  }
}

/// The custom color picker: hue, saturation and brightness, with the
/// chosen color and its value.
class CustomColorPicker extends StatefulWidget {
  final String color;
  final void Function(String color, bool done) onChanged;
  const CustomColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
  });

  @override
  State<CustomColorPicker> createState() => _CustomColorPickerState();
}

class _CustomColorPickerState extends State<CustomColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(inkColor(widget.color));

  @override
  void didUpdateWidget(CustomColorPicker old) {
    super.didUpdateWidget(old);
    // A color from elsewhere (a fixed swatch) moves the controls; the
    // picker's own value keeps its hue even at no saturation.
    if (widget.color.toUpperCase() != storedColor(_hsv.toColor())) {
      _hsv = HSVColor.fromColor(inkColor(widget.color));
    }
  }

  void _set(HSVColor hsv, bool done) {
    setState(() => _hsv = hsv);
    widget.onChanged(storedColor(hsv.toColor()), done);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final value = storedColor(_hsv.toColor());
    return Container(
      key: const Key('custom-color'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      decoration: BoxDecoration(
        color: c.subtle,
        borderRadius: BorderRadius.circular(appRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: c.control),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                value.substring(0, 7),
                key: const Key('custom-color-value'),
                style: text.labelMedium,
              ),
            ],
          ),
          SettingSlider(
            key: const Key('custom-hue'),
            label: context.tr('hue'),
            value: _hsv.hue,
            display: '${_hsv.hue.round()}°',
            min: 0,
            max: 360,
            divisions: 72,
            onChanged: (v) => _set(_hsv.withHue(v.clamp(0, 359.9)), false),
            onEnd: (v) => _set(_hsv.withHue(v.clamp(0, 359.9)), true),
          ),
          SettingSlider(
            key: const Key('custom-saturation'),
            label: context.tr('saturation'),
            value: _hsv.saturation,
            display: '${(_hsv.saturation * 100).round()}%',
            min: 0,
            max: 1,
            divisions: 20,
            onChanged: (v) => _set(_hsv.withSaturation(v), false),
            onEnd: (v) => _set(_hsv.withSaturation(v), true),
          ),
          SettingSlider(
            key: const Key('custom-brightness'),
            label: context.tr('brightness'),
            value: _hsv.value,
            display: '${(_hsv.value * 100).round()}%',
            min: 0,
            max: 1,
            divisions: 20,
            onChanged: (v) => _set(_hsv.withValue(v), false),
            onEnd: (v) => _set(_hsv.withValue(v), true),
          ),
        ],
      ),
    );
  }
}

// Mark preview ------------------------------------------------------------

/// A small mark with the current settings, drawn by the same brush outline
/// as the page (B6.2). The brush pen preview varies its pressure along the
/// mark to show what pen pressure does; it is never stored.
class MarkPreviewPainter extends CustomPainter {
  MarkPreviewPainter({required this.tool, required this.style, this.shape});

  final DrawTool tool;
  final InkStyle style;
  final ShapeKind? shape;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = tool.pen == null ? _shapeOutline(size) : _penOutline(size);
    if (outline == null) return;
    final path = Path();
    for (final piece in outline.pieces) {
      path.addPolygon([for (final v in piece) Offset(v.x, v.y)], true);
    }
    canvas.drawPath(path, Paint()..color = Color(outline.argb));
  }

  InkOutline? _penOutline(Size size) {
    final pen = tool.pen!;
    final capture = StrokeCapture(
      BrushSettings(
        tool: pen,
        width: style.width,
        color: style.color,
        opacity: style.opacity,
        tipAngle: pen == InkTool.flat ? (style.tipAngle ?? 0) : null,
      ),
      pageWidth: size.width,
    );
    const steps = 48;
    final left = 24.0, right = size.width - 24;
    final amplitude = math.max(4.0, size.height / 2 - 12);
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      capture.add(
        left + (right - left) * t,
        size.height / 2 - amplitude * math.sin(t * 2 * math.pi),
        i * 8,
        pressure: pen == InkTool.brush
            ? 0.15 + 0.85 * math.sin(t * math.pi)
            : null,
      );
    }
    final item = DocumentItem.fromJson(
      capture.toItem('preview')!,
      family: DocumentFamily.original,
    );
    return item is StrokeItem ? strokeOutline(item) : null;
  }

  InkOutline? _shapeOutline(Size size) {
    final side = size.height - 20;
    final kind = shape ?? ShapeKind.rectangle;
    final half = kind == ShapeKind.circle ? side / 2 : side * 0.8;
    final json = shapeFromDrag(
      'preview',
      kind,
      InkVec(size.width / 2 - half, 10),
      InkVec(size.width / 2 + half, 10 + side),
      ShapeStyle(
        color: style.color,
        lineWidth: style.width,
        opacity: style.opacity,
      ),
      minSize: 0,
    );
    if (json == null) return null;
    final item = DocumentItem.fromJson(json, family: DocumentFamily.original);
    return item is ShapeItem ? shapeOutline(item)?.line : null;
  }

  @override
  bool shouldRepaint(MarkPreviewPainter old) =>
      old.tool != tool ||
      old.shape != shape ||
      old.style.width != style.width ||
      old.style.color != style.color ||
      old.style.opacity != style.opacity ||
      old.style.tipAngle != style.tipAngle;
}

/// The settings of the eraser (B2.6, B6.6): the circle size, the normal
/// modes (partial or whole stroke, free ink only) and the dangerous
/// delete-anything mode. Delete anything is off at first, red while on, and
/// turned on and off with a text button (a critical action has a label).
class EraserSettingsPanel extends StatelessWidget {
  final EraserSettings eraser;
  final bool dangerous, warning, instant;
  final DrawSettings settings;
  final void Function(EraserMode mode) onMode;
  final void Function(num radius, bool done) onRadius;
  final ValueChanged<bool> onDangerous;
  final VoidCallback onCloseWarning;
  const EraserSettingsPanel({
    super.key,
    required this.eraser,
    required this.dangerous,
    required this.warning,
    required this.instant,
    required this.onMode,
    required this.onRadius,
    required this.onDangerous,
    required this.onCloseWarning,
    this.settings = const DrawSettings(),
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final radius = eraser.radius.toDouble().clamp(
      settings.minEraserRadius.toDouble(),
      settings.maxEraserRadius.toDouble(),
    );
    Widget choice(EraserMode mode, String label) => Expanded(
      child: _Choice(
        key: Key('eraser-mode-${mode.name}'),
        label: context.tr(label),
        selected: eraser.mode == mode,
        onTap: () => onMode(mode),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        key: const Key('eraser-settings'),
        width: 296,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(dangerous ? 'eraserDangerous' : 'eraser'),
              style: text.titleSmall,
            ),
            const SizedBox(height: 8),
            SettingSlider(
              key: const Key('eraser-size'),
              label: context.tr('eraserSize'),
              value: radius,
              display: '${(radius * 2).round()}',
              min: settings.minEraserRadius.toDouble(),
              max: settings.maxEraserRadius.toDouble(),
              divisions: (settings.maxEraserRadius - settings.minEraserRadius)
                  .round(),
              onChanged: (v) => onRadius(v.round(), false),
              onEnd: (v) => onRadius(v.round(), true),
            ),
            // Delete anything removes whole objects, so the line choice is
            // hidden while it is on; the previous choice comes back after.
            if (!dangerous) ...[
              const SizedBox(height: 4),
              Text(context.tr('eraserMode'), style: text.labelMedium),
              const SizedBox(height: 6),
              Row(
                children: [
                  choice(EraserMode.partialStroke, 'eraserPartial'),
                  const SizedBox(width: 4),
                  choice(EraserMode.wholeStroke, 'eraserWhole'),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                context.tr('eraserNormalHint'),
                style: text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
            const SizedBox(height: 12),
            if (dangerous)
              AppButton(
                key: const Key('eraser-dangerous-off'),
                label: context.tr('eraserDangerousOff'),
                onPressed: () => onDangerous(false),
              )
            else
              AppButton.danger(
                key: const Key('eraser-dangerous-on'),
                label: context.tr('eraserDangerousOn'),
                icon: AppIcons.alertTriangle,
                onPressed: () => onDangerous(true),
              ),
            if (dangerous && warning) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('eraser-danger-warning'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(appRadius),
                  border: Border.all(color: c.danger, width: 2),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(AppIcons.alertTriangle, size: 18, color: c.danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr(
                          instant
                              ? 'eraserDangerWarningInstant'
                              : 'eraserDangerWarning',
                        ),
                        style: text.bodySmall,
                      ),
                    ),
                    AppIconButton(
                      key: const Key('eraser-danger-warning-close'),
                      icon: AppIcons.close,
                      label: context.tr('close'),
                      onPressed: onCloseWarning,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One choice of a small set, with the green selection fill when chosen.
class _Choice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
          splashFactory: NoSplash.splashFactory,
          foregroundColor: WidgetStatePropertyAll(
            selected ? c.onSelection : c.text,
          ),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => selected
                ? c.selection
                : s.contains(WidgetState.hovered)
                ? c.subtle
                : Colors.transparent,
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(appRadius),
              side: BorderSide(color: selected ? c.selectionOutline : c.border),
            ),
          ),
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
