/// The live editor of the open text block and its space limit feedback
/// (annotations#27, B2.3).
///
/// The editor is laid out in page units at the stored block width and
/// scaled by the view zoom, so the rendered height is the measured height
/// that the editor rules store. The red border, the shake and the message
/// stay inside the block area on screen: they never change the document,
/// the page length or a neighbor.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

import '../../../../dal/local/quill_text_engine.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/text_handler.dart';

class TextBlockLayer extends StatelessWidget {
  final TextHandler text;
  final PaperView view;
  const TextBlockLayer({super.key, required this.text, required this.view});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: text,
    builder: (context, _) {
      final controller = text.controller;
      final block = text.block;
      if (controller == null || block == null) return const SizedBox.shrink();
      final c = context.colors;
      final settings = text.paper.settings;
      final pad = settings.framePadding;
      final screen = view.rectToScreen(block);
      // The editor draws the text in the mode color, like the content layer;
      // a color does not change the layout.
      final styles = QuillTextEngine(
        style: text.engine.style.copyWith(color: c.text),
      ).styles;
      return Stack(
        children: [
          Positioned(
            left: screen.left - pad,
            top: screen.top - pad,
            width: screen.width + 2 * pad,
            height: screen.height + 2 * pad,
            child: _Shake(
              key: const Key('text-limit-shake'),
              ticks: text.shakes,
              duration: settings.limitShake,
              distance: settings.limitShakeDistance,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: pad,
                    top: pad,
                    child: Transform.scale(
                      scale: view.zoom,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: block.width,
                        child: _editorTheme(
                          context,
                          QuillEditor(
                            key: text.editorKey,
                            controller: controller,
                            focusNode: text.focus,
                            scrollController: text.scroll,
                            config: QuillEditorConfig(
                              customStyles: styles,
                              scrollable: false,
                              padding: EdgeInsets.zero,
                              // The page decides when a block closes: a click
                              // elsewhere on the page or a new block.
                              onTapOutside: (_, _) {},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (text.limited)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const Key('text-limit-border'),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.danger, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // The message is a temporary overlay anchored at the block (Hippo
          // beba260d): it covers the block area and, when the block is too
          // small for readable text, it extends over the paper below and to
          // the right. It never takes page space or moves a neighbor.
          if (text.messageShown)
            Positioned(
              left: screen.left,
              top: screen.top,
              width: math.max(screen.width, settings.limitMessageMinWidth),
              child: _Shake(
                ticks: text.shakes,
                duration: settings.limitShake,
                distance: settings.limitShakeDistance,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: screen.height),
                  child: SpaceLimitMessage(
                    onOk: text.ok,
                    onDontShowAgain: text.dontShowAgain,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// The selection mark of note text: the selection green, see-through enough
/// that the selected text stays readable (H7 colors rule 3).
Widget _editorTheme(BuildContext context, Widget child) {
  final c = context.colors;
  final theme = Theme.of(context);
  return Theme(
    data: theme.copyWith(
      textSelectionTheme: theme.textSelectionTheme.copyWith(
        selectionColor: c.selection.withValues(alpha: 0.4),
        cursorColor: c.text,
      ),
    ),
    child: child,
  );
}

/// The short space limit message on a solid surface. It covers the text and
/// never deletes it, and its text keeps the normal UI size (never scaled
/// down).
class SpaceLimitMessage extends StatelessWidget {
  final VoidCallback onOk;
  final VoidCallback onDontShowAgain;
  const SpaceLimitMessage({
    super.key,
    required this.onOk,
    required this.onDontShowAgain,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: c.text);
    final message = Text(
      context.tr('spaceLimit'),
      key: const Key('text-limit-text'),
      style: style,
    );
    final ok = AppButton.primary(
      key: const Key('text-limit-ok'),
      label: context.tr('ok'),
      onPressed: onOk,
    );
    final never = AppButton.subtle(
      key: const Key('text-limit-never'),
      label: context.tr('dontShowAgain'),
      onPressed: onDontShowAgain,
    );
    return Semantics(
      key: const Key('text-limit-message'),
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              message,
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 4, children: [ok, never]),
            ],
          ),
        ),
      ),
    );
  }
}

/// A brief sideways shake on each new tick. A tick during a shake does not
/// start it again (no repeated movement on a held key), and reduced motion
/// has no shake: the red border stays as the static indicator.
class _Shake extends StatefulWidget {
  final ValueListenable<int> ticks;
  final Duration duration;
  final double distance;
  final Widget child;
  const _Shake({
    super.key,
    required this.ticks,
    required this.duration,
    required this.distance,
    required this.child,
  });

  @override
  State<_Shake> createState() => _ShakeState();
}

class _ShakeState extends State<_Shake> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    widget.ticks.addListener(_tick);
  }

  @override
  void didUpdateWidget(_Shake old) {
    super.didUpdateWidget(old);
    if (old.ticks != widget.ticks) {
      old.ticks.removeListener(_tick);
      widget.ticks.addListener(_tick);
    }
  }

  void _tick() {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    if (!controller.isAnimating) controller.forward(from: 0);
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_tick);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder: (context, child) {
      final t = controller.value;
      final dx = controller.isAnimating
          ? math.sin(t * math.pi * 6) * widget.distance * (1 - t)
          : 0.0;
      return Transform.translate(offset: Offset(dx, 0), child: child);
    },
  );
}
