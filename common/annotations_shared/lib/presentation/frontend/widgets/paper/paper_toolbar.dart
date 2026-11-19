import 'package:flutter/material.dart';

import '../../../../domain/models/toolbar_placement.dart';
import '../../../../domain/services/draw_tools.dart';
import '../../components/controls.dart';
import '../../components/draw_controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/text_tools.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/attachment_handler.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/point_edit_handler.dart';
import '../../handlers/selection_handler.dart';
import '../../handlers/text_handler.dart';
import 'draw_toolbar.dart';
import 'attachment_layer.dart';
import 'point_edit_layer.dart';
import 'selection_layer.dart';

/// The editor toolbar (annotations#31; B7 rules and behaviors).
///
/// 1. It starts at the top; it docks at any edge or floats.
/// 2. The move handle drags it (a drop near an edge docks there); the
///    position menu does the same without dragging.
/// 3. Its controls follow the mode: Type has the text tools of the open
///    block; Draw has the pens, highlighter, shapes, eraser and the
///    selection tool; a selected drawing has Edit points, and point editing
///    has its commands.
/// 4. Tapping the active tool opens its settings (the tool buttons).
/// 5. The settings keep the text and point selection (their own widgets).
/// 6. Collapse keeps the active tool and Expand, and a clear warning while
///    Delete anything is on.
/// 7. The placement is kept on this device ([placement], [onPlacement]).
/// 8. It stays inside the screen; the screen moves it away from the keyboard.
/// Narrow screens put the other drawing tools in a More menu and keep the
/// active one visible. Notes has Undo and Redo; Instant has neither.
class PaperToolbar extends StatefulWidget {
  final PaperHandler paper;
  final DrawHandler draw;
  final TextHandler text;
  final PointEditHandler points;

  /// The object actions, the move and the size controls of a selection in
  /// Type mode (annotations#32), the ways that need no drag.
  final SelectionHandler? selection;

  /// The Add menu and the card actions (annotations#34).
  final AttachmentHandler? attachments;
  final ToolbarPlacement placement;
  final ValueChanged<ToolbarPlacement> onPlacement;

  /// The drag of the move handle in global positions, while it moves; the
  /// screen shows the toolbar there and docks or floats it on release.
  final ValueChanged<Offset> onDrag;
  final ValueChanged<Offset> onDrop;

  /// The longest side the toolbar may take (the screen side minus margins).
  final double extent;

  /// The visible exit of Focus (B7); null when Focus is off.
  final VoidCallback? onExitFocus;

  const PaperToolbar({
    super.key,
    required this.paper,
    required this.draw,
    required this.text,
    required this.points,
    this.selection,
    this.attachments,
    required this.placement,
    required this.onPlacement,
    required this.onDrag,
    required this.onDrop,
    required this.extent,
    this.onExitFocus,
  });

  @override
  State<PaperToolbar> createState() => _PaperToolbarState();
}

class _PaperToolbarState extends State<PaperToolbar> {
  bool _collapsed = false;

  /// The space of one icon control in the toolbar direction (the button
  /// with its tap target and focus ring), and of a divider.
  static const _slot = 56.0;
  static const _gap = 9.0;

  /// Below this length the position and collapse controls share one menu.
  static const _narrow = 640.0;

  bool get _isNarrow => widget.extent < _narrow;

  Axis get _axis =>
      widget.placement.edge.vertical ? Axis.vertical : Axis.horizontal;

  Widget _divider(AppColors c) => Container(
    width: _axis == Axis.horizontal ? 1 : 24,
    height: _axis == Axis.horizontal ? 24 : 1,
    margin: const EdgeInsets.all(4),
    color: c.border,
  );

  Widget _handle(BuildContext context) => AppTooltip(
    message: context.tr('toolbarMove'),
    child: Semantics(
      label: context.tr('toolbarMove'),
      child: GestureDetector(
        key: const Key('toolbar-move'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => widget.onDrag(d.globalPosition),
        onPanEnd: (d) => widget.onDrop(d.globalPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: SizedBox.square(
            dimension: 36,
            child: Center(
              child: AppIcon(
                AppIcons.move,
                size: 18,
                color: context.colors.icon,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _positionMenu(BuildContext context) {
    final edge = widget.placement.edge;
    AppMenuEntry entry(ToolbarEdge e, String label) => AppMenuEntry(
      key: Key('toolbar-at-${e.name}'),
      label: context.tr(label),
      checked: edge == e,
      onSelected: () => widget.onPlacement(widget.placement.docked(e)),
    );
    return AppMenuButton(
      key: const Key('toolbar-position'),
      icon: AppIcons.position,
      label: context.tr('toolbarPosition'),
      entries: [
        entry(ToolbarEdge.top, 'toolbarTop'),
        entry(ToolbarEdge.bottom, 'toolbarBottom'),
        entry(ToolbarEdge.left, 'toolbarLeft'),
        entry(ToolbarEdge.right, 'toolbarRight'),
        entry(ToolbarEdge.floating, 'toolbarFloating'),
        // On a narrow screen Collapse sits in the same menu.
        if (_isNarrow && !_collapsed)
          AppMenuEntry(
            key: const Key('toolbar-collapse-entry'),
            label: context.tr('toolbarCollapse'),
            icon: AppIcons.collapse,
            onSelected: () => setState(() => _collapsed = true),
          ),
      ],
    );
  }

  Widget _collapse(BuildContext context) => AppIconButton(
    key: Key(_collapsed ? 'toolbar-expand' : 'toolbar-collapse'),
    icon: _collapsed ? AppIcons.expand : AppIcons.collapse,
    label: context.tr(_collapsed ? 'toolbarExpand' : 'toolbarCollapse'),
    onPressed: () => setState(() => _collapsed = !_collapsed),
  );

  List<Widget> _history(BuildContext context) {
    final paper = widget.paper;
    if (!paper.hasHistory) return const [];
    void run(VoidCallback action) {
      // A live text block ends first, so one history serves both.
      widget.text.end();
      action();
    }

    return [
      AppIconButton(
        key: const Key('toolbar-undo'),
        icon: AppIcons.undo,
        label: context.tr('undo'),
        onPressed: paper.canUndo ? () => run(paper.undo) : null,
      ),
      AppIconButton(
        key: const Key('toolbar-redo'),
        icon: AppIcons.redo,
        label: context.tr('redo'),
        onPressed: paper.canRedo ? () => run(paper.redo) : null,
      ),
    ];
  }

  /// The drawing tools that fit, with the active one always among them, and
  /// the rest for the More menu.
  (List<DrawTool>, List<DrawTool>) _fit(double room) {
    const tools = DrawTool.values;
    final active = widget.draw.tools.active;
    final count = (room / _slot).floor();
    if (count >= tools.length) return (tools, const <DrawTool>[]);
    final others = tools.where((t) => t != active);
    final kept = others.take((count - 1).clamp(0, tools.length)).toSet();
    final shown = [
      for (final t in tools)
        if (t == active || kept.contains(t)) t,
    ];
    return (
      shown,
      [
        for (final t in tools)
          if (!shown.contains(t)) t,
      ],
    );
  }

  Widget _more(BuildContext context, List<DrawTool> tools) => AppMenuButton(
    key: const Key('toolbar-more'),
    icon: AppIcons.menu,
    label: context.tr('toolbarMore'),
    entries: [
      for (final t in tools)
        AppMenuEntry(
          key: Key('toolbar-more-${t.name}'),
          label: drawToolLabel(context, t),
          icon: drawToolIcon(t),
          onSelected: () => widget.draw.selectTool(t),
        ),
    ],
  );

  /// Move by one grid cell and, for one object, Narrower and Wider by one
  /// cell (B2.2, B3.4): the ways without a drag, in one menu so the toolbar
  /// keeps one row. The arrow keys move too.
  List<Widget> _moveAndSize(BuildContext context, SelectionHandler s) => [
    AppMenuButton(
      key: const Key('selection-arrange'),
      icon: AppIcons.move,
      label: context.tr('selectionArrange'),
      entries: [
        for (final (key, icon, label, x, y) in [
          ('left', AppIcons.chevronLeft, 'selectionMoveLeft', -1, 0),
          ('up', AppIcons.chevronUp, 'selectionMoveUp', 0, -1),
          ('down', AppIcons.chevronDown, 'selectionMoveDown', 0, 1),
          ('right', AppIcons.chevronRight, 'selectionMoveRight', 1, 0),
        ])
          AppMenuEntry(
            key: Key('selection-move-$key'),
            icon: icon,
            label: context.tr(label),
            onSelected: () => s.nudge(x, y),
          ),
        if (s.sizeTarget != null) ...[
          AppMenuEntry(
            key: const Key('selection-narrower'),
            label: context.tr('selectionNarrower'),
            onSelected: () => s.resizeBy(-1),
          ),
          AppMenuEntry(
            key: const Key('selection-wider'),
            label: context.tr('selectionWider'),
            onSelected: () => s.resizeBy(1),
          ),
        ],
      ],
    ),
  ];

  Widget _dangerNotice(BuildContext context) {
    final c = context.colors;
    final notice = Container(
      key: const Key('toolbar-danger'),
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(appRadius),
        border: Border.all(color: c.danger, width: 2),
      ),
      child: Flex(
        direction: _axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(AppIcons.alertTriangle, size: 16, color: c.danger),
          const SizedBox(width: 6, height: 6),
          if (_axis == Axis.horizontal)
            Text(
              context.tr('eraserDangerous'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
        ],
      ),
    );
    // A vertical toolbar shows the mark; its name is the tooltip and the
    // screen reader text.
    return Semantics(
      label: context.tr('eraserDangerOn'),
      child: AppTooltip(message: context.tr('eraserDangerOn'), child: notice),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final paper = widget.paper, draw = widget.draw, text = widget.text;
    final points = widget.points;
    final vertical = _axis == Axis.vertical;
    final drawMode = draw.isDrawMode;
    final children = <Widget>[
      _handle(context),
      _positionMenu(context),
      if (!_isNarrow || _collapsed) _collapse(context),
      _divider(c),
    ];
    if (_collapsed) {
      // The active tool stays visible, and the Delete anything warning.
      if (drawMode) {
        children.add(DrawToolButton(draw: draw, tool: draw.tools.active));
        if (draw.dangerous) children.add(_dangerNotice(context));
      } else {
        children.add(
          ModeSwitch(
            mode: draw.mode,
            onChanged: draw.setMode,
            axis: _axis,
            compact: true,
          ),
        );
      }
    } else {
      children.add(
        ModeSwitch(
          mode: draw.mode,
          onChanged: draw.setMode,
          axis: _axis,
          compact: vertical || _isNarrow,
        ),
      );
      final history = _history(context);
      if (history.isNotEmpty) children.addAll([_divider(c), ...history]);
      if (widget.attachments case final files?
          when !drawMode &&
              text.controller == null &&
              (widget.selection?.selection.isEmpty ?? true)) {
        children.add(AddMenu(attachments: files));
      }
      if (drawMode && points.active) {
        children.addAll([
          _divider(c),
          PointEditPanel(points: points, axis: _axis, bare: true),
        ]);
      } else if (drawMode) {
        // Room for the drawing tools after the fixed controls.
        final compact = vertical || _isNarrow;
        final fixed =
            36 +
            _slot * ((_isNarrow ? 1 : 2) + (history.isEmpty ? 0 : 2)) +
            (compact ? 104 : 190) +
            _gap * (history.isEmpty ? 2 : 3) +
            (points.selectedTarget != null ? _slot : 0) +
            8;
        final (shown, rest) = _fit(widget.extent - fixed - _slot);
        children.addAll([
          _divider(c),
          DrawToolbar(draw: draw, axis: _axis, bare: true, tools: shown),
          if (rest.isNotEmpty) _more(context, rest),
          if (points.selectedTarget case final id?)
            AppIconButton(
              key: const Key('edit-points'),
              icon: AppIcons.path,
              label: context.tr('editPoints'),
              onPressed: () => points.start(id),
            ),
        ]);
        if (draw.dangerous && vertical) children.add(_dangerNotice(context));
      } else if (widget.selection case final selection?
          when selection.selection.isNotEmpty && text.controller == null) {
        final card = selection.sizeTarget;
        final files = widget.attachments;
        children.addAll([
          _divider(c),
          ...selectionActions(context, selection),
          if (files != null && card != null && files.cardKind(card) != null)
            CardMenu(attachments: files, id: card),
          _divider(c),
          ..._moveAndSize(context, selection),
        ]);
      } else if (text.controller case final controller?) {
        children.addAll([
          _divider(c),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => TextTools(
              format: text.format,
              baseSize: paper.textStyle.fontSize ?? 16,
              settings: paper.settings,
              onToggle: text.toggle,
              onSize: text.size,
              onColor: text.color,
              axis: _axis,
              bare: true,
            ),
          ),
        ]);
      }
    }
    if (widget.onExitFocus case final exit?) {
      children.addAll([
        _divider(c),
        AppButton(
          key: const Key('toolbar-exit-focus'),
          label: context.tr('exitFocus'),
          onPressed: exit,
        ),
      ]);
    }
    return Semantics(
      container: true,
      label: context.tr('toolbar'),
      child: Container(
        key: const Key('paper-toolbar'),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(appPanelRadius),
          border: Border.all(color: c.border),
        ),
        // A very small window wraps the controls instead of cutting them.
        child: Wrap(
          direction: _axis,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      ),
    );
  }
}
