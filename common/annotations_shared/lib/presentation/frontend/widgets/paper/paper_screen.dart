import 'package:flutter/material.dart';

import '../../components/paper_controls.dart';
import '../../components/save_state.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../../../domain/models/toolbar_placement.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/point_edit_handler.dart';
import '../../handlers/text_handler.dart';
import 'eraser_layer.dart';
import 'paper_canvas.dart';
import 'paper_toolbar.dart';
import 'point_edit_layer.dart';
import 'text_block_editor.dart';

/// The writing surface of one note: the paper canvas with its status panel
/// (save state, paper background and zoom). The same screen serves phones
/// and desktops: a screen size changes only the view (B1.1).
///
/// Type mode (annotations#27): a click on the page opens or starts a text
/// block through the [TextHandler]; while a block is open, its text tools
/// show at the top, where the toolbar starts (B7 rule 1).
///
/// Type and Draw (annotations#28): editing starts in Type mode and the
/// mode switch stays visible at the top center. Draw mode shows the pens
/// and the shapes next to it; Type mode shows the text tools there while a
/// block is open. This is the temporary place until the toolbar
/// (annotations#31) takes these controls.
///
/// The toolbar (annotations#31) and the corner view lock (annotations#33)
/// come later; [foreground] passes their page widgets to the canvas.
class PaperScreen extends StatefulWidget {
  final PaperHandler handler;
  final Widget Function(BuildContext context, PaperView view)? foreground;

  /// The text flow; the screen makes one with the app preferences when null.
  final TextHandler? text;

  /// The modes and drawing tools; the screen makes one when null.
  final DrawHandler? draw;

  /// Point editing of one drawing; the screen makes one when null.
  final PointEditHandler? points;
  const PaperScreen({
    super.key,
    required this.handler,
    this.foreground,
    this.text,
    this.draw,
    this.points,
  });

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  TextHandler? _own;
  DrawHandler? _ownDraw;
  PointEditHandler? _ownPoints;

  ToolbarPlacement? _placement;

  /// The toolbar position while its move handle drags it (local offset).
  Offset? _dragAt;

  ToolbarPlacement get placement =>
      _placement ?? AppScope.of(context).preferences.toolbar;

  void _place(ToolbarPlacement value) {
    setState(() {
      _placement = value;
      _dragAt = null;
    });
    AppScope.of(context).preferences.saveToolbar(value);
  }

  /// The margin between the toolbar and the screen edges.
  static const _margin = 12.0;

  /// A drop this close to an edge docks the toolbar there.
  static const _dock = 56.0;

  Offset _local(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }

  void _drop(Offset global, Size size) {
    final p = _local(global);
    final edge = p.dy < _dock
        ? ToolbarEdge.top
        : p.dy > size.height - _dock
        ? ToolbarEdge.bottom
        : p.dx < _dock
        ? ToolbarEdge.left
        : p.dx > size.width - _dock
        ? ToolbarEdge.right
        : ToolbarEdge.floating;
    _place(
      edge == ToolbarEdge.floating
          ? placement.floating(p.dx / size.width, p.dy / size.height)
          : placement.docked(edge),
    );
  }

  /// The toolbar at its placement, inside the screen. A keyboard that would
  /// cover it moves it up; the stored placement stays, so it comes back
  /// (B7 rule 8).
  Widget _toolbar(BuildContext context, Size size) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final p = placement;
    final vertical = p.edge.vertical;
    final bar = PaperToolbar(
      paper: widget.handler,
      draw: draw,
      text: text,
      points: points,
      placement: p,
      onPlacement: _place,
      onDrag: (g) => setState(() => _dragAt = _local(g)),
      onDrop: (g) => _drop(g, size),
      extent: (vertical ? size.height : size.width) - 2 * _margin,
    );
    final drag = _dragAt;
    final Alignment align;
    if (drag != null) {
      align = Alignment(
        (drag.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
        (drag.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
      );
    } else {
      align = switch (p.edge) {
        ToolbarEdge.top => Alignment.topCenter,
        ToolbarEdge.bottom => Alignment.bottomCenter,
        ToolbarEdge.left => Alignment.centerLeft,
        ToolbarEdge.right => Alignment.centerRight,
        ToolbarEdge.floating => Alignment(p.x * 2 - 1, p.y * 2 - 1),
      };
    }
    final lowHalf = align.y > 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _margin,
        _margin,
        _margin,
        _margin + (keyboard > 0 && lowHalf ? keyboard : 0),
      ),
      child: Align(
        key: const Key('toolbar-place'),
        alignment: align,
        child: bar,
      ),
    );
  }

  TextHandler get text => widget.text ?? _own!;
  DrawHandler get draw => widget.draw ?? _ownDraw!;
  PointEditHandler get points => widget.points ?? _ownPoints!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preferences = AppScope.of(context).preferences;
    if (widget.text == null && _own == null) {
      _own = TextHandler(paper: widget.handler, preferences: preferences);
    }
    if (widget.draw == null && _ownDraw == null) {
      _ownDraw = DrawHandler(
        paper: widget.handler,
        preferences: preferences,
        onDrawMode: () => text.end(),
      );
    }
    if (widget.points == null && _ownPoints == null) {
      _ownPoints = PointEditHandler(draw: draw);
    }
  }

  @override
  void dispose() {
    _ownPoints?.dispose();
    _own?.dispose();
    _ownDraw?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      PaperCanvas(
        handler: widget.handler,
        onTap: (local, global) => text.tapAt(local, global: global),
        input: points,
        foreground: (context, view) => Stack(
          fit: StackFit.expand,
          children: [
            TextBlockLayer(text: text, view: view),
            EraserLayer(draw: draw, view: view),
            PointEditLayer(points: points, view: view),
            if (widget.foreground != null) widget.foreground!(context, view),
          ],
        ),
      ),
      Positioned.fill(
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: Listenable.merge([
              draw,
              text,
              points,
              widget.handler,
              widget.handler.selection,
            ]),
            builder: (context, _) => _toolbar(context, box.biggest),
          ),
        ),
      ),
      Positioned(
        right: 12,
        bottom: 12,
        child: PaperStatusPanel(handler: widget.handler),
      ),
    ],
  );
}

/// A solid panel at the bottom right: Saving, Saved or Not saved with Retry;
/// the Paper button; Zoom out, the zoom level and Zoom in.
class PaperStatusPanel extends StatelessWidget {
  final PaperHandler handler;
  const PaperStatusPanel({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget divider() => Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: c.border,
    );
    return Container(
      key: const Key('paper-status'),
      padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(appPanelRadius),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SaveStateIndicator(
            state: handler.saveState,
            onRetry: handler.retrySave,
          ),
          divider(),
          ListenableBuilder(
            listenable: Listenable.merge([handler, handler.preview]),
            builder: (context, _) => PaperBackgroundButton(
              guides: handler.guides,
              settings: handler.settings,
              onPick: handler.pickPattern,
              onPreview: handler.previewGuides,
              onCommit: handler.setGuides,
            ),
          ),
          ValueListenableBuilder(
            valueListenable: handler.view,
            builder: (context, view, _) => ZoomControls(
              zoom: view?.zoom ?? 1,
              onZoomIn: handler.canZoomIn ? handler.zoomIn : null,
              onZoomOut: handler.canZoomOut ? handler.zoomOut : null,
            ),
          ),
        ],
      ),
    );
  }
}
