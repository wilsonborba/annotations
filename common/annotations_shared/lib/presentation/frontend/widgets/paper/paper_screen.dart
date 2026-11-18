import 'package:flutter/material.dart';

import '../../components/paper_controls.dart';
import '../../components/save_state.dart';
import '../../components/scope.dart';
import '../../components/text_tools.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/text_handler.dart';
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
/// The toolbar (annotations#31) and the corner view lock (annotations#33)
/// come later; [foreground] passes their page widgets to the canvas.
class PaperScreen extends StatefulWidget {
  final PaperHandler handler;
  final Widget Function(BuildContext context, PaperView view)? foreground;

  /// The text flow; the screen makes one with the app preferences when null.
  final TextHandler? text;
  const PaperScreen({
    super.key,
    required this.handler,
    this.foreground,
    this.text,
  });

  @override
  State<PaperScreen> createState() => _PaperScreenState();
}

class _PaperScreenState extends State<PaperScreen> {
  TextHandler? _own;

  TextHandler get text => widget.text ?? _own!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.text == null && _own == null) {
      _own = TextHandler(
        paper: widget.handler,
        preferences: AppScope.of(context).preferences,
      );
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      PaperCanvas(
        handler: widget.handler,
        onTap: (local, global) => text.tapAt(local, global: global),
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
            listenable: text,
            builder: (context, _) {
              final controller = text.controller;
              if (controller == null) return const SizedBox.shrink();
              return ListenableBuilder(
                listenable: controller,
                builder: (context, _) => TextTools(
                  format: text.format,
                  baseSize: widget.handler.textStyle.fontSize ?? 16,
                  settings: widget.handler.settings,
                  onToggle: text.toggle,
                  onSize: text.size,
                  onColor: text.color,
                ),
              );
            },
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
