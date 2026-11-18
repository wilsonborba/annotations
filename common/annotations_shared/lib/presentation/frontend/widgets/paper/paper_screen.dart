import 'package:flutter/material.dart';

import '../../components/paper_controls.dart';
import '../../components/save_state.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import 'paper_canvas.dart';

/// The writing surface of one note: the paper canvas with its status panel
/// (save state, paper background and zoom). The same screen serves phones
/// and desktops: a screen size changes only the view (B1.1).
///
/// The toolbar (annotations#31) and the corner view lock (annotations#33)
/// come later; [foreground] passes their page widgets to the canvas.
class PaperScreen extends StatelessWidget {
  final PaperHandler handler;
  final Widget Function(BuildContext context, PaperView view)? foreground;
  const PaperScreen({super.key, required this.handler, this.foreground});

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      PaperCanvas(handler: handler, foreground: foreground),
      Positioned(
        right: 12,
        bottom: 12,
        child: PaperStatusPanel(handler: handler),
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
