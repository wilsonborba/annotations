/// What the selection gestures show on the page (annotations#32): the
/// proposed position or size while dragging (red when the drop would be
/// rejected), the selection box or lasso, and for touch a small menu near
/// the selection.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/selection_handler.dart';

class SelectionLayer extends StatelessWidget {
  final SelectionHandler selection;
  final PaperView view;
  const SelectionLayer({
    super.key,
    required this.selection,
    required this.view,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              key: const Key('selection-layer'),
              painter: _SelectionPainter(
                view: view,
                proposal: selection.proposal,
                band: selection.band,
                colors: c,
                padding: selection.paper.settings.framePadding,
              ),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([
            selection,
            selection.paper.pointer,
            selection.paper,
          ]),
          builder: (context, _) =>
              selection.menuShown ? _menu(context) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// The touch menu above the selection, or below it near the top.
  Widget _menu(BuildContext context) {
    Rect? bounds;
    for (final id in selection.selection.ids) {
      final r = selection.paper.layout?.rectOf(id);
      if (r == null) continue;
      final s = view.rectToScreen(
        Rect.fromLTRB(
          r.left.toDouble(),
          r.top.toDouble(),
          r.right.toDouble(),
          r.bottom.toDouble(),
        ),
      );
      bounds = bounds == null ? s : bounds.expandToInclude(s);
    }
    if (bounds == null) return const SizedBox.shrink();
    // Out of the room of a docked toolbar: above the selection when it
    // fits there, else below it.
    const height = 52.0, gap = 12.0;
    final insets = selection.paper.toolbarInsets;
    final minTop = insets.top + 8;
    final maxTop = math.max(
      minTop,
      view.size.height - insets.bottom - height - 8,
    );
    final above = bounds.top - height - gap >= minTop;
    final top = above ? bounds.top - height - gap : bounds.bottom + gap;
    return Positioned(
      left: insets.left,
      right: insets.right,
      top: top.clamp(minTop, maxTop),
      child: Center(child: SelectionMenu(selection: selection)),
    );
  }
}

/// The object actions near the selection on touch (B2 G1).
class SelectionMenu extends StatelessWidget {
  final SelectionHandler selection;
  const SelectionMenu({super.key, required this.selection});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const Key('selection-menu'),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(appPanelRadius),
        border: Border.all(color: c.border),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: selectionActions(context, selection),
      ),
    );
  }
}

/// The buttons of the object actions, for the touch menu and the toolbar.
List<Widget> selectionActions(
  BuildContext context,
  SelectionHandler selection,
) => [
  AppIconButton(
    key: const Key('selection-copy'),
    icon: AppIcons.copy,
    label: context.tr('selectionCopy'),
    onPressed: selection.copy,
  ),
  AppIconButton(
    key: const Key('selection-cut'),
    icon: AppIcons.cut,
    label: context.tr('selectionCut'),
    onPressed: selection.cut,
  ),
  AppButton(
    key: const Key('selection-paste'),
    label: context.tr('selectionPaste'),
    onPressed: selection.paste,
  ),
  AppIconButton(
    key: const Key('selection-duplicate'),
    icon: AppIcons.duplicate,
    label: context.tr('selectionDuplicate'),
    onPressed: selection.duplicate,
  ),
  if (selection.canGroup)
    AppIconButton(
      key: const Key('selection-group'),
      icon: AppIcons.group,
      label: context.tr('selectionGroup'),
      onPressed: selection.group,
    ),
  if (selection.canUngroup)
    AppButton(
      key: const Key('selection-ungroup'),
      label: context.tr('selectionUngroup'),
      onPressed: selection.ungroup,
    ),
  AppIconButton(
    key: const Key('selection-delete'),
    icon: AppIcons.delete,
    label: context.tr('selectionDelete'),
    onPressed: selection.delete,
  ),
];

class _SelectionPainter extends CustomPainter {
  _SelectionPainter({
    required this.view,
    required this.proposal,
    required this.band,
    required this.colors,
    required this.padding,
  }) : super(repaint: Listenable.merge([proposal, band]));

  final PaperView view;
  final ValueNotifier<SelectionProposal?> proposal;
  final ValueNotifier<SelectionBand?> band;
  final AppColors colors;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (proposal.value case final p?) {
      final color = p.valid ? colors.selectionOutline : colors.danger;
      final fill = Paint()..color = color.withValues(alpha: 0.12);
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = p.valid ? 1.5 : 2.5
        ..color = color;
      for (final f in p.frames) {
        final r = RRect.fromRectAndRadius(
          view.rectToScreen(f).inflate(padding),
          const Radius.circular(4),
        );
        canvas
          ..drawRRect(r, fill)
          ..drawRRect(r, line);
      }
    }
    if (band.value case final b?) {
      final fill = Paint()
        ..color = colors.selectionOutline.withValues(alpha: 0.10);
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.selectionOutline;
      if (b.lasso) {
        final path = Path();
        for (final (i, p) in b.points.indexed) {
          final s = view.toScreen(p);
          i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
        }
        path.close();
        canvas
          ..drawPath(path, fill)
          ..drawPath(path, line);
      } else {
        final r = Rect.fromPoints(
          view.toScreen(b.points.first),
          view.toScreen(b.points.last),
        );
        canvas
          ..drawRect(r, fill)
          ..drawRect(r, line);
      }
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.view != view ||
      old.proposal != proposal ||
      old.band != band ||
      old.colors != colors;
}

/// The short notice after Undo or Redo with the steps back and forward
/// (B2 G2). It shows for [PaperSettings.historyNotice], then disappears.
class HistoryNoticeView extends StatelessWidget {
  final PaperHandler paper;
  const HistoryNoticeView({super.key, required this.paper});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: paper.historyNotice,
    builder: (context, notice, _) {
      if (notice == null) return const SizedBox.shrink();
      final c = context.colors;
      String steps(int n, String one, String many) =>
          n == 1 ? context.tr(one) : context.tr(many).replaceAll('{n}', '$n');
      final text =
          '${context.tr(notice.undo ? 'undo' : 'redo')}: '
          '${steps(notice.back, 'historyStepBack', 'historyStepsBack')}, '
          '${steps(notice.forward, 'historyStepForward', 'historyStepsForward')}';
      return Semantics(
        liveRegion: true,
        child: Container(
          key: const Key('history-notice'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: c.inverse,
            borderRadius: BorderRadius.circular(appPanelRadius),
          ),
          child: Text(text, style: TextStyle(color: c.onInverse, fontSize: 14)),
        ),
      );
    },
  );
}
