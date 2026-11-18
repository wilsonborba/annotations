import 'package:flutter/material.dart';

import '../../../../domain/services/draw_tools.dart';
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
/// A temporary panel at the top until the toolbar (annotations#31) takes
/// these controls.
class DrawToolbar extends StatelessWidget {
  final DrawHandler draw;
  const DrawToolbar({super.key, required this.draw});

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
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(appPanelRadius),
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tool in DrawTool.values)
                _ToolButton(draw: draw, tool: tool),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final DrawHandler draw;
  final DrawTool tool;
  const _ToolButton({required this.draw, required this.tool});

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    // A tap outside closes the settings without drawing (B7 rule 3).
    consumeOutsideTap: true,
    menuChildren: [
      ListenableBuilder(
        listenable: draw,
        builder: (context, _) {
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
            settings: draw.settings,
          );
        },
      ),
    ],
    builder: (context, controller, _) {
      final active = draw.tools.active == tool;
      return AppIconButton(
        key: Key('draw-tool-${tool.name}'),
        icon: drawToolIcon(tool),
        label: drawToolLabel(context, tool),
        selected: active,
        onPressed: () {
          if (!active) {
            controller.close();
            draw.selectTool(tool);
          } else if (controller.isOpen) {
            controller.close();
          } else {
            controller.open();
          }
        },
      );
    },
  );
}
