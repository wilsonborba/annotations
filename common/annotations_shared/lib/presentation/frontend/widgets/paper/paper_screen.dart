import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/paper_controls.dart';
import '../../components/save_state.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../../../domain/models/toolbar_placement.dart';
import '../../../../domain/services/reports_embed_source.dart';
import '../../../../domain/services/task_card_service.dart';
import '../../../../dal/local/dropped_files.dart';
import '../../handlers/attachment_handler.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/point_edit_handler.dart';
import '../../handlers/selection_handler.dart';
import '../../handlers/text_handler.dart';
import 'attachment_layer.dart';
import 'eraser_layer.dart';
import 'paper_canvas.dart';
import 'paper_toolbar.dart';
import 'point_edit_layer.dart';
import 'selection_layer.dart';
import 'text_block_editor.dart';
import 'note_embedded_cards_layer.dart';

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

  /// Selection, move, resize and the object actions; made when null.
  final SelectionHandler? selection;

  /// Focus started or ended (B8): the host hides its own navigation while
  /// Focus is on.
  final ValueChanged<bool>? onFocusChanged;

  /// Files and links (annotations#34); made when null.
  final AttachmentHandler? attachments;

  /// Link previews from the server for cloud notes; local notes have none.
  final LinkPreviewSource? linkPreview;

  /// Auth-scoped Reports source for live/snapshot note cards.
  final ReportsEmbedSource? reportsSource;
  final String? trustedReportsAccountId;
  final bool publicProjection;
  final String reportsLanguage;

  /// Loads one account-authorized task by its saved reference.
  final Future<TaskSummary?> Function(String taskId)? loadTaskCard;

  /// Replaces the save state in the status panel: an Instant room shows its
  /// sharing state there (annotations#44).
  final Widget? status;

  /// Simple typed controls (A2 matrix, phones and the phone browser in an
  /// Instant room): a tap types; every object stays visible, but there is
  /// no drawing, selection, move, resize, point editing, adding of files or
  /// change of the paper background.
  final bool typedOnly;

  /// Disables document editing while an Instant room is disconnected.
  final bool readOnly;
  const PaperScreen({
    super.key,
    required this.handler,
    this.foreground,
    this.text,
    this.draw,
    this.points,
    this.selection,
    this.onFocusChanged,
    this.attachments,
    this.linkPreview,
    this.reportsSource,
    this.trustedReportsAccountId,
    this.publicProjection = false,
    this.reportsLanguage = 'en',
    this.loadTaskCard,
    this.status,
    this.typedOnly = false,
    this.readOnly = false,
  });

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  TextHandler? _own;
  DrawHandler? _ownDraw;
  PointEditHandler? _ownPoints;
  SelectionHandler? _ownSelection;
  AttachmentHandler? _ownAttachments;

  ToolbarPlacement? _placement;

  /// Focus (B8): the tools, Type and Draw, the lock and Exit Focus stay;
  /// the status panel goes. Content, selection, mode, view and history stay,
  /// and Focus does not lock the view. It ends with the editor.
  bool _focus = false;

  @override
  void initState() {
    super.initState();
    widget.handler.editingEnabled = !widget.readOnly;
  }

  @override
  void didUpdateWidget(PaperScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.handler.editingEnabled = !widget.readOnly;
    if (!oldWidget.readOnly && widget.readOnly) {
      text.end();
      text.focus.unfocus();
    }
  }

  void _setFocus(bool on) {
    if (on == _focus) return;
    setState(() => _focus = on);
    widget.onFocusChanged?.call(on);
  }

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

  /// The side of the corner lock control.
  static const _lockSide = 62.0;

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
  /// The room of a docked toolbar: its thickness and the margin.
  static const _toolbarRoom = 72.0;

  EdgeInsets _insetsFor(ToolbarPlacement p) => switch (p.edge) {
    ToolbarEdge.top => const EdgeInsets.only(top: _toolbarRoom),
    ToolbarEdge.bottom => const EdgeInsets.only(bottom: _toolbarRoom),
    ToolbarEdge.left => const EdgeInsets.only(left: _toolbarRoom),
    ToolbarEdge.right => const EdgeInsets.only(right: _toolbarRoom),
    ToolbarEdge.floating => EdgeInsets.zero,
  };

  Widget _toolbar(BuildContext context, Size size) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final p = placement;
    // A docked toolbar takes its edge, so the whole page stays reachable;
    // a floating one lies over the page.
    final insets = _insetsFor(p);
    if (insets != widget.handler.toolbarInsets) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.handler.toolbarInsets = insets;
      });
    }
    final vertical = p.edge.vertical;
    final bar = PaperToolbar(
      paper: widget.handler,
      draw: draw,
      text: text,
      points: points,
      selection: widget.typedOnly ? null : selection,
      attachments: widget.typedOnly ? null : attachments,
      typedOnly: widget.typedOnly,
      placement: p,
      onPlacement: _place,
      onDrag: (g) => setState(() => _dragAt = _local(g)),
      onDrop: (g) => _drop(g, size),
      onExitFocus: _focus ? () => _setFocus(false) : null,
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
        child: IgnorePointer(ignoring: widget.readOnly, child: bar),
      ),
    );
  }

  TextHandler get text => widget.text ?? _own!;
  DrawHandler get draw => widget.draw ?? _ownDraw!;
  PointEditHandler get points => widget.points ?? _ownPoints!;
  SelectionHandler get selection => widget.selection ?? _ownSelection!;
  AttachmentHandler get attachments => widget.attachments ?? _ownAttachments!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preferences = AppScope.of(context).preferences;
    widget.handler.fingerNavigation = preferences.fingerNavigation;
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
    if (widget.attachments == null && _ownAttachments == null) {
      _ownAttachments = AttachmentHandler(
        paper: widget.handler,
        preview: widget.linkPreview,
      );
    }
    if (widget.selection == null && _ownSelection == null) {
      _ownSelection = SelectionHandler(
        paper: widget.handler,
        text: text,
        draw: draw,
        next: points,
        attachments: attachments,
        confirmRemove: () => confirmRemove(context),
      );
    }
  }

  @override
  void dispose() {
    _ownSelection?.dispose();
    _ownAttachments?.dispose();
    _ownPoints?.dispose();
    _own?.dispose();
    _ownDraw?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      _droppable(
        enabled: !widget.typedOnly && !widget.readOnly,
        formats: dropFormats,
        hitTestBehavior: HitTestBehavior.opaque,
        onDropOver: (_) => DropOperation.copy,
        onPerformDrop: (event) async {
          final view = widget.handler.view.value;
          if (view == null) return;
          final dropped = await readDropped([
            for (final item in event.session.items) ?item.dataReader,
          ]);
          await attachments.drop(
            dropped.paths,
            dropped.texts,
            view.toPage(event.position.local),
          );
        },
        child: IgnorePointer(
          ignoring: widget.readOnly,
          child: PaperCanvas(
            handler: widget.handler,
            onTap: widget.typedOnly
                ? (local, global) => text.tapAt(local, global: global)
                : selection.tap,
            input: widget.typedOnly ? null : selection,
            onKey: widget.readOnly
                ? (_) => KeyEventResult.handled
                : widget.typedOnly
                ? null
                : selection.key,
            onWheel: attachments.wheel,
            foreground: (context, view) => Stack(
              fit: StackFit.expand,
              children: [
                TextBlockLayer(text: text, view: view),
                if (!widget.typedOnly) ...[
                  EraserLayer(draw: draw, view: view),
                  PointEditLayer(points: points, view: view),
                  SelectionLayer(selection: selection, view: view),
                  AttachmentJobsLayer(attachments: attachments, view: view),
                ],
                if (widget.reportsSource != null ||
                    widget.loadTaskCard != null ||
                    widget.publicProjection)
                  NoteEmbeddedCardsLayer(
                    document: widget.handler.document,
                    view: view,
                    reportsSource: widget.reportsSource,
                    trustedAccountId: widget.trustedReportsAccountId,
                    publicProjection: widget.publicProjection,
                    language: widget.reportsLanguage,
                    loadTask: widget.loadTaskCard,
                  ),
                if (widget.foreground != null)
                  widget.foreground!(context, view),
              ],
            ),
          ),
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
              selection,
            ]),
            builder: (context, _) => _toolbar(context, box.biggest),
          ),
        ),
      ),
      // Right of the corner lock; a narrow screen wraps the panel.
      if (!_focus)
        Positioned(
          left: 12 + _lockSide + 8,
          right: 12,
          bottom: 12,
          child: Align(
            alignment: Alignment.bottomRight,
            child: PaperStatusPanel(
              handler: widget.handler,
              onFocus: () => _setFocus(true),
              status: widget.status,
              background: !widget.typedOnly && !widget.readOnly,
            ),
          ),
        ),
      Positioned(
        left: 12,
        bottom: 12,
        child: ViewLockButton(handler: widget.handler),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 72,
        child: IgnorePointer(
          child: Center(child: HistoryNoticeView(paper: widget.handler)),
        ),
      ),
    ],
  );
}

/// A solid panel at the bottom right: Saving, Saved or Not saved with Retry;
/// the Paper button; Zoom out, the zoom level and Zoom in.
class PaperStatusPanel extends StatelessWidget {
  final PaperHandler handler;

  /// Starts Focus; the Focus button shows when it is set.
  final VoidCallback? onFocus;

  /// Shown instead of the save state (an Instant room's sharing state).
  final Widget? status;

  /// The Paper button; false where backgrounds are display only.
  final bool background;
  const PaperStatusPanel({
    super.key,
    required this.handler,
    this.onFocus,
    this.status,
    this.background = true,
  });

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
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          status ??
              SaveStateIndicator(
                state: handler.saveState,
                onRetry: handler.retrySave,
              ),
          // Instant's longer Shared/Retry status can fill a phone row. Keep
          // the separator with the controls instead of stranding it after
          // Retry when Wrap moves the controls to the next row.
          if (status == null) divider(),
          if (background)
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
          ListenableBuilder(
            listenable: Listenable.merge([handler.view, handler]),
            builder: (context, _) => ZoomControls(
              zoom: handler.view.value?.zoom ?? 1,
              onZoomIn: handler.canZoomIn && !handler.locked
                  ? handler.zoomIn
                  : null,
              onZoomOut: handler.canZoomOut && !handler.locked
                  ? handler.zoomOut
                  : null,
            ),
          ),
          FingerSettingsButton(handler: handler),
          if (onFocus != null)
            AppButton(
              key: const Key('focus-start'),
              label: context.tr('focus'),
              onPressed: onFocus,
            ),
        ],
      ),
    );
  }
}

/// The corner lock (B8): a tap, a click or the keyboard locks or unlocks
/// the page position and zoom. It shows in Focus too.
class ViewLockButton extends StatelessWidget {
  final PaperHandler handler;
  const ViewLockButton({super.key, required this.handler});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: handler,
    builder: (context, _) {
      final c = context.colors;
      final locked = handler.locked;
      return Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(appPanelRadius),
          border: Border.all(color: c.border),
        ),
        padding: const EdgeInsets.all(2),
        child: AppIconButton(
          key: const Key('view-lock'),
          icon: locked ? AppIcons.lock : AppIcons.lockOpen,
          label: context.tr(locked ? 'unlockView' : 'lockView'),
          selected: locked,
          onPressed: () => handler.locked = !locked,
        ),
      );
    },
  );
}

/// The finger settings (B8): finger navigation (on at first) and finger
/// drawing (off at first), kept on this device.
class FingerSettingsButton extends StatelessWidget {
  final PaperHandler handler;
  const FingerSettingsButton({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    final preferences = AppScope.of(context).preferences;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => AppMenuButton(
        key: const Key('finger-settings'),
        icon: AppIcons.hand,
        label: context.tr('fingerSettings'),
        entries: [
          AppMenuEntry(
            key: const Key('finger-navigation'),
            label: context.tr('fingerNavigation'),
            checked: preferences.fingerNavigation,
            onSelected: () {
              final on = !preferences.fingerNavigation;
              handler.fingerNavigation = on;
              preferences.setFingerNavigation(on);
            },
          ),
          AppMenuEntry(
            key: const Key('finger-drawing'),
            label: context.tr('fingerDrawing'),
            checked: preferences.fingerDrawing,
            onSelected: () =>
                preferences.setFingerDrawing(!preferences.fingerDrawing),
          ),
        ],
      ),
    );
  }
}

/// Drag and drop of files and links needs the native drop plugin. Widget
/// tests have no native plugins, so the region is left out there.
Widget _droppable({
  bool enabled = true,
  required List<DataFormat> formats,
  required HitTestBehavior hitTestBehavior,
  required DropOperation Function(DropOverEvent) onDropOver,
  required Future<void> Function(PerformDropEvent) onPerformDrop,
  required Widget child,
}) {
  final binding = WidgetsBinding.instance.runtimeType.toString();
  if (!enabled || binding.contains('TestWidgetsFlutterBinding')) return child;
  return DropRegion(
    formats: formats,
    hitTestBehavior: hitTestBehavior,
    onDropOver: onDropOver,
    onPerformDrop: onPerformDrop,
    child: child,
  );
}
