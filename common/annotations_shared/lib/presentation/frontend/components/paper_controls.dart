import 'package:flutter/material.dart';

import '../../../core/paper_settings.dart';
import '../../../domain/services/paper_page.dart';
import 'controls.dart';
import 'icons.dart';
import 'paper_guides.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

String paperLabel(BuildContext context, PaperPattern pattern) =>
    context.tr(switch (pattern) {
      PaperPattern.blank => 'paperBlank',
      PaperPattern.ruled => 'paperRuled',
      PaperPattern.grid => 'paperGrid',
      PaperPattern.dots => 'paperDots',
    });

/// The Paper button: a subtle icon button that opens the background panel.
class PaperBackgroundButton extends StatelessWidget {
  final PaperGuides guides;
  final ValueChanged<PaperPattern> onPick;
  final ValueChanged<PaperGuides> onPreview;
  final ValueChanged<PaperGuides> onCommit;
  final PaperSettings settings;
  const PaperBackgroundButton({
    super.key,
    required this.guides,
    required this.onPick,
    required this.onPreview,
    required this.onCommit,
    this.settings = const PaperSettings(),
  });

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    menuChildren: [
      PaperBackgroundPanel(
        guides: guides,
        onPick: onPick,
        onPreview: onPreview,
        onCommit: onCommit,
        settings: settings,
      ),
    ],
    builder: (context, controller, _) => AppIconButton(
      key: const Key('paper-button'),
      icon: AppIcons.paper,
      label: context.tr('paper'),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

/// The background choices with their spacing and visibility (B4.1, B4.2).
/// A choice saves at once; a slider shows its value while it moves and saves
/// once when it is released.
class PaperBackgroundPanel extends StatelessWidget {
  final PaperGuides guides;
  final ValueChanged<PaperPattern> onPick;
  final ValueChanged<PaperGuides> onPreview;
  final ValueChanged<PaperGuides> onCommit;
  final PaperSettings settings;
  const PaperBackgroundPanel({
    super.key,
    required this.guides,
    required this.onPick,
    required this.onPreview,
    required this.onCommit,
    this.settings = const PaperSettings(),
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final blank = guides.pattern == PaperPattern.blank;
    final spacing = (guides.spacing ?? settings.ruledSpacing).toDouble().clamp(
      settings.minSpacing.toDouble(),
      settings.maxSpacing.toDouble(),
    );
    final visibility = (guides.visibility ?? settings.defaultVisibility)
        .toDouble()
        .clamp(settings.minVisibility.toDouble(), 1.0);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 312,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('paper'), style: text.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final p in PaperPattern.values) ...[
                  if (p != PaperPattern.blank) const SizedBox(width: 8),
                  Expanded(
                    child: _Choice(
                      pattern: p,
                      selected: guides.pattern == p,
                      onTap: () => onPick(p),
                    ),
                  ),
                ],
              ],
            ),
            if (!blank) ...[
              const SizedBox(height: 14),
              _Setting(
                key: const Key('paper-spacing'),
                label: context.tr('paperSpacing'),
                value: spacing,
                display: '${spacing.round()}',
                min: settings.minSpacing.toDouble(),
                max: settings.maxSpacing.toDouble(),
                divisions: (settings.maxSpacing - settings.minSpacing).round(),
                onChanged: (v) =>
                    onPreview(guides.copyWith(spacing: v.round())),
                onEnd: (v) => onCommit(guides.copyWith(spacing: v.round())),
              ),
              _Setting(
                key: const Key('paper-visibility'),
                label: context.tr('paperVisibility'),
                value: visibility,
                display: '${(visibility * 100).round()}%',
                min: settings.minVisibility.toDouble(),
                max: 1,
                divisions: ((1 - settings.minVisibility) * 20).round(),
                onChanged: (v) => onPreview(
                  guides.copyWith(visibility: (v * 100).round() / 100),
                ),
                onEnd: (v) => onCommit(
                  guides.copyWith(visibility: (v * 100).round() / 100),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final PaperPattern pattern;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({
    required this.pattern,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: paperLabel(context, pattern),
      excludeSemantics: true,
      child: TextButton(
        key: Key('paper-${pattern.code}'),
        onPressed: onTap,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          // The current choice: the green selection fill with dark text.
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
              side: BorderSide(
                color: selected ? c.selectionOutline : Colors.transparent,
              ),
            ),
          ),
        ),
        child: Column(
          children: [
            DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(border: Border.all(color: c.border)),
              child: PaperSwatch(guides: PaperGuides.pick(pattern)),
            ),
            const SizedBox(height: 6),
            Text(
              paperLabel(context, pattern),
              maxLines: 2,
              textAlign: TextAlign.center,
              style: text.labelSmall!.copyWith(
                color: selected ? c.onSelection : c.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Setting extends StatelessWidget {
  final String label, display;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged, onEnd;
  const _Setting({
    super.key,
    required this.label,
    required this.display,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onEnd,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: text.labelMedium)),
            Text(display, style: text.labelMedium),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            activeTrackColor: c.selectionOutline,
            inactiveTrackColor: c.border,
            thumbColor: c.selectionOutline,
            overlayColor: Colors.transparent,
            activeTickMarkColor: Colors.transparent,
            inactiveTickMarkColor: Colors.transparent,
            showValueIndicator: ShowValueIndicator.never,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            semanticFormatterCallback: (_) => display,
            onChanged: onChanged,
            onChangeEnd: onEnd,
          ),
        ),
      ],
    );
  }
}

/// Zoom out, the zoom level and Zoom in (owner basis B1-B2: add zoom).
class ZoomControls extends StatelessWidget {
  final double zoom;
  final VoidCallback? onZoomIn, onZoomOut;
  const ZoomControls({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final percent = '${(zoom * 100).round()}%';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIconButton(
          key: const Key('zoom-out'),
          icon: AppIcons.zoomOut,
          label: context.tr('zoomOut'),
          onPressed: onZoomOut,
        ),
        Semantics(
          label: context.tr('zoomLevel'),
          value: percent,
          excludeSemantics: true,
          child: SizedBox(
            width: 48,
            child: Text(
              percent,
              key: const Key('zoom-level'),
              textAlign: TextAlign.center,
              style: text.labelMedium,
            ),
          ),
        ),
        AppIconButton(
          key: const Key('zoom-in'),
          icon: AppIcons.zoomIn,
          label: context.tr('zoomIn'),
          onPressed: onZoomIn,
        ),
      ],
    );
  }
}
