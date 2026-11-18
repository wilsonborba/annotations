import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../domain/models/ink.dart';
import '../../../../domain/services/ink_geometry.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/point_edit_handler.dart';

/// The points of the edited drawing over the page (annotations#29): the
/// path outline, a square per node and, for the selected node, its handles
/// with their lines. While a drag moves, the outline shows the proposed
/// path. A rejected change draws the outline red.
class PointEditLayer extends StatelessWidget {
  final PointEditHandler points;
  final PaperView view;
  const PointEditLayer({super.key, required this.points, required this.view});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: points,
    builder: (context, _) {
      if (!points.active) return const SizedBox.shrink();
      return IgnorePointer(
        child: CustomPaint(
          key: const Key('point-edit-layer'),
          painter: _PointsPainter(
            nodes: points.nodes,
            closed: points.closed,
            selected: points.node,
            rejected: points.rejected != null,
            view: view,
            colors: context.colors,
          ),
          size: Size.infinite,
        ),
      );
    },
  );
}

class _PointsPainter extends CustomPainter {
  _PointsPainter({
    required this.nodes,
    required this.closed,
    required this.selected,
    required this.rejected,
    required this.view,
    required this.colors,
  });

  final List<InkNode> nodes;
  final bool closed, rejected;
  final int? selected;
  final PaperView view;
  final AppColors colors;

  Offset _screen(InkVec v) => view.toScreen(Offset(v.x, v.y));

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = rejected ? colors.danger : colors.selectionOutline;
    final path = Path();
    final points = nodes.length == 1
        ? [nodes.first.point]
        : [
            for (final p in flatten(segmentsOf(nodes, closed: closed), 0.25))
              p.point,
          ];
    path.moveTo(_screen(points.first).dx, _screen(points.first).dy);
    for (final p in points.skip(1)) {
      final s = _screen(p);
      path.lineTo(s.dx, s.dy);
    }
    canvas.drawPath(path, line);
    // Handles of the selected node.
    final i = selected;
    if (i != null && i < nodes.length) {
      final n = nodes[i];
      for (final h in [n.inPoint, n.outPoint]) {
        if (h == null) continue;
        canvas.drawLine(_screen(n.point), _screen(h), line);
        canvas.drawCircle(_screen(h), 4.5, Paint()..color = colors.surface);
        canvas.drawCircle(_screen(h), 4.5, line);
      }
    }
    for (var k = 0; k < nodes.length; k++) {
      final r = Rect.fromCenter(
        center: _screen(nodes[k].point),
        width: 9,
        height: 9,
      );
      canvas.drawRect(
        r,
        Paint()..color = k == i ? colors.selection : colors.surface,
      );
      canvas.drawRect(r, line..strokeWidth = k == i ? 2 : 1.5);
    }
  }

  @override
  bool shouldRepaint(_PointsPainter old) => true;
}

/// The commands of point editing, with click and keyboard alternatives to
/// every drag (B6.3): add, remove, corner, smooth, the handle mode, and Done.
/// Keys: arrows move the selected point (Shift: 10 units), Tab and Shift Tab
/// select the next or previous point, Delete removes it, C makes a corner,
/// S makes it smooth, Escape ends point editing.
class PointEditPanel extends StatefulWidget {
  final PointEditHandler points;

  /// The direction and whether the commands sit bare inside the editor
  /// toolbar (annotations#31).
  final Axis axis;
  final bool bare;
  const PointEditPanel({
    super.key,
    required this.points,
    this.axis = Axis.horizontal,
    this.bare = false,
  });

  @override
  State<PointEditPanel> createState() => _PointEditPanelState();
}

class _PointEditPanelState extends State<PointEditPanel> {
  final _focus = FocusNode(debugLabel: 'point editing');

  PointEditHandler get points => widget.points;

  @override
  void initState() {
    super.initState();
    // The keys reach point editing at once, without a click on the panel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final step = shift ? 10 : 1;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      points.nudge(-step, 0);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      points.nudge(step, 0);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      points.nudge(0, -step);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      points.nudge(0, step);
    } else if (key == LogicalKeyboardKey.tab) {
      points.selectNext(back: shift);
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      points.removeNode();
    } else if (key == LogicalKeyboardKey.keyC) {
      points.makeCorner();
    } else if (key == LogicalKeyboardKey.keyS) {
      points.makeSmooth();
    } else if (key == LogicalKeyboardKey.escape) {
      points.done();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: points,
      builder: (context, _) {
        final i = points.node;
        final n = i != null && i < points.nodes.length ? points.nodes[i] : null;
        final has = n != null;
        AppMenuEntry mode(NodeMode m, String label) => AppMenuEntry(
          key: Key('point-mode-${m.name}'),
          label: context.tr(label),
          checked: n != null && !n.corner && n.mode == m,
          onSelected: () => points.setMode(m),
        );
        return Focus(
          key: const Key('point-edit-keys'),
          focusNode: _focus,
          onKeyEvent: (_, event) => _key(event),
          child: Semantics(
            container: true,
            label: context.tr('editPoints'),
            child: Container(
              key: const Key('point-edit-panel'),
              padding: widget.bare ? EdgeInsets.zero : const EdgeInsets.all(4),
              decoration: widget.bare
                  ? null
                  : BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(appPanelRadius),
                      border: Border.all(color: c.border),
                    ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    direction: widget.axis,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    runSpacing: 2,
                    children: [
                      AppIconButton(
                        key: const Key('point-add'),
                        icon: AppIcons.add,
                        label: context.tr('pointAdd'),
                        onPressed: points.addNode,
                      ),
                      AppIconButton(
                        key: const Key('point-remove'),
                        icon: AppIcons.delete,
                        label: context.tr('pointRemove'),
                        onPressed: has ? points.removeNode : null,
                      ),
                      AppIconButton(
                        key: const Key('point-corner'),
                        icon: AppIcons.triangle,
                        label: context.tr('pointCorner'),
                        selected: n?.corner ?? false,
                        onPressed: has ? points.makeCorner : null,
                      ),
                      AppIconButton(
                        key: const Key('point-smooth'),
                        icon: AppIcons.circle,
                        label: context.tr('pointSmooth'),
                        onPressed: has ? points.makeSmooth : null,
                      ),
                      Container(
                        width: widget.axis == Axis.horizontal ? 1 : 20,
                        height: widget.axis == Axis.horizontal ? 20 : 1,
                        margin: const EdgeInsets.all(4),
                        color: c.border,
                      ),
                      if (has)
                        AppMenuButton(
                          key: const Key('point-mode'),
                          icon: AppIcons.path,
                          label: context.tr('handleMode'),
                          entries: [
                            mode(NodeMode.independent, 'handleIndependent'),
                            mode(NodeMode.smooth, 'handleSmooth'),
                            mode(NodeMode.symmetric, 'handleSymmetric'),
                          ],
                        ),
                      Container(
                        width: widget.axis == Axis.horizontal ? 1 : 20,
                        height: widget.axis == Axis.horizontal ? 20 : 1,
                        margin: const EdgeInsets.all(4),
                        color: c.border,
                      ),
                      AppButton(
                        key: const Key('point-done'),
                        label: context.tr('pointsDone'),
                        onPressed: points.done,
                      ),
                    ],
                  ),
                  if (points.rejected != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            AppIcons.alertDiamond,
                            size: 16,
                            color: c.danger,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            context.tr(switch (points.rejected!.code) {
                              'block_overlap' ||
                              'group_overlap' => 'pointEditRejected',
                              'too_few_nodes' => 'pointEditTooFew',
                              'out_of_bounds' => 'pointEditOutside',
                              _ => 'pointEditNotPossible',
                            }),
                            key: const Key('point-edit-rejected'),
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
