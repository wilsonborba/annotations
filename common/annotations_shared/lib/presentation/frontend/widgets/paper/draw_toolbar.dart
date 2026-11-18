import 'package:flutter/material.dart';

import '../../../../domain/services/draw_tools.dart';
import '../../../../domain/services/note_history.dart' show NotesEditor;
import '../../components/controls.dart';
import '../../components/draw_controls.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/draw_handler.dart';

/// The tools of Draw mode: the four pens and the shapes (B6.1, B6.4), as
/// subtle icon buttons with their names as tooltips. The active tool has the
/// green selection fill; tapping it again opens its settings (B7 rule 3).
///
/// The editor toolbar (annotations#31) holds them bare, in its direction;
/// tools that do not fit go to its More menu ([tools] is what shows here).
class DrawToolbar extends StatelessWidget {
  final DrawHandler draw;
  final Axis axis;
  final bool bare;
  final List<DrawTool> tools;
  const DrawToolbar({
    super.key,
    required this.draw,
    this.axis = Axis.horizontal,
    this.bare = false,
    this.tools = DrawTool.values,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: draw,
      builder: (context, _) => Semantics(
        container: true,
        label: context.tr('drawTools'),
        child: Container(
          key: const Key('draw-tools'),
          padding: bare ? EdgeInsets.zero : const EdgeInsets.all(2),
          decoration: bare
              ? null
              : BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(appPanelRadius),
                  border: Border.all(color: c.border),
                ),
          child: Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tool in tools) DrawToolButton(draw: draw, tool: tool),
            ],
          ),
        ),
      ),
    );
  }
}

/// One drawing tool: tapping it selects it, tapping the active tool opens
/// its settings (B7 rule 4). The eraser is red while Delete anything is on.
class DrawToolButton extends StatelessWidget {
  final DrawHandler draw;
  final DrawTool tool;
  const DrawToolButton({super.key, required this.draw, required this.tool});

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    // A tap outside closes the settings without drawing (B7 rule 3).
    consumeOutsideTap: true,
    menuChildren: [
      ListenableBuilder(
        listenable: draw,
        builder: (context, _) {
          // The selection tool has no settings.
          if (tool == DrawTool.select) return const SizedBox.shrink();
          if (tool == DrawTool.eraser) {
            return EraserSettingsPanel(
              eraser: draw.tools.eraser,
              dangerous: draw.dangerous,
              warning: draw.dangerWarning,
              instant: draw.paper.session is! NotesEditor,
              settings: draw.settings,
              onMode: (mode) => draw.setEraser(mode: mode),
              onRadius: (radius, done) =>
                  draw.setEraser(radius: radius, done: done),
              onDangerous: draw.setDangerous,
              onCloseWarning: draw.closeDangerWarning,
            );
          }
          final shapes = tool == DrawTool.shapes;
          return ToolSettingsPanel(
            tool: tool,
            style: draw.style,
            selection: draw.editsSelection,
            showsTipAngle: draw.showsTipAngle,
            maxWidth: draw.maxWidth,
            shape: shapes ? draw.previewShape : null,
            // The shape choice is for new shapes; selected ink keeps its
            // shape.
            onShape: shapes && !draw.editsSelection ? draw.selectShape : null,
            onChange: (change, done) => draw.change(change, done: done),
            onEditAsPath: shapes && draw.pathTarget != null
                ? draw.editAsPath
                : null,
            onApplyStyle: tool.pen != null && draw.selectedStrokeIds.isNotEmpty
                ? () => draw.applyPenStyle(tool)
                : null,
            settings: draw.settings,
          );
        },
      ),
    ],
    builder: (context, controller, _) {
      final active = draw.tools.active == tool;
      // Delete anything shows a red active state on the eraser (B2.6).
      final danger = tool == DrawTool.eraser && draw.dangerous;
      final button = AppIconButton(
        key: Key('draw-tool-${tool.name}'),
        icon: drawToolIcon(tool),
        label: danger
            ? context.tr('eraserDangerous')
            : drawToolLabel(context, tool),
        selected: active && !danger,
        onPressed: () {
          if (!active) {
            controller.close();
            draw.selectTool(tool);
          } else if (tool == DrawTool.select) {
            return;
          } else if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        },
      );
      if (!danger) return button;
      return DecoratedBox(
        key: const Key('eraser-danger-state'),
        decoration: BoxDecoration(
          color: context.colors.danger,
          borderRadius: BorderRadius.circular(appRadius),
        ),
        child: button,
      );
    },
  );
}
