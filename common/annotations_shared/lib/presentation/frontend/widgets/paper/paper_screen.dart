import 'package:flutter/material.dart';

import '../../components/draw_controls.dart';
import '../../components/paper_controls.dart';
import '../../components/save_state.dart';
import '../../components/scope.dart';
import '../../components/text_tools.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/text_handler.dart';
import 'draw_toolbar.dart';
import 'paper_canvas.dart';
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
  const PaperScreen({
    super.key,
    required this.handler,
    this.foreground,
    this.text,
    this.draw,
  });

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  TextHandler? _own;
  DrawHandler? _ownDraw;

  TextHandler get text => widget.text ?? _own!;
  DrawHandler get draw => widget.draw ?? _ownDraw!;

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
  }

  @override
  void dispose() {
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
        input: draw,
        foreground: (context, view) => Stack(
          fit: StackFit.expand,
          children: [
            TextBlockLayer(text: text, view: view),
            if (widget.foreground != null) widget.foreground!(context, view),
          ],
        ),
      ),
      Positioned(
        top: 12,
        left: 12,
        right: 12,
        child: Center(
          child: ListenableBuilder(
            listenable: Listenable.merge([draw, text]),
            builder: (context, _) => Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                ModeSwitch(mode: draw.mode, onChanged: draw.setMode),
                if (draw.isDrawMode)
                  DrawToolbar(draw: draw)
                else if (text.controller case final controller?)
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => TextTools(
                      format: text.format,
                      baseSize: widget.handler.textStyle.fontSize ?? 16,
                      settings: widget.handler.settings,
                      onToggle: text.toggle,
                      onSize: text.size,
                      onColor: text.color,
                    ),
                  ),
              ],
            ),
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
