import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../../domain/services/object_selection.dart';
import '../../components/paper_guides.dart';
import '../../components/tokens.dart';
import '../../handlers/draw_handler.dart';
import '../../handlers/paper_handler.dart';
import 'paper_layers.dart';

/// The long paper page in document coordinates (B1.1). Zoom and pan change
/// only the [PaperHandler.view]; the document positions stay as stored.
///
/// Navigation input: the wheel scrolls (Shift for sideways), Ctrl or Cmd
/// with the wheel zooms at the pointer, a trackpad pans and pinches, touch
/// pans with one finger and pinches with two, Ctrl or Cmd with + and -
/// zooms. A mouse drag and the pen never move the page: they are kept for
/// selection (annotations#32) and writing (annotations#28).
///
/// [input] gets every pointer event of the page (the Draw mode pens and
/// shapes). A stroke in progress blocks navigation (B8).
///
/// [foreground] is the hook for widgets placed on the page by later tools
/// (a live text editor, cards); it gets the current view. [onTap] gets a
/// click or tap on the page that no foreground widget took, in screen
/// pixels of the canvas.
class PaperCanvas extends StatefulWidget {
  final PaperHandler handler;
  final Widget Function(BuildContext context, PaperView view)? foreground;
  final void Function(Offset local, Offset global)? onTap;
  final PaperInput? input;

  /// Keys of the page before its own zoom keys (the selection shortcuts).
  final KeyEventResult Function(KeyEvent event)? onKey;

  /// A wheel at a screen point before the page scrolls: true when a block
  /// took it (a CSV table scrolls inside, annotations#34).
  final bool Function(Offset local, Offset delta)? onWheel;
  const PaperCanvas({
    super.key,
    required this.handler,
    this.foreground,
    this.onTap,
    this.input,
    this.onKey,
    this.onWheel,
  });

  @override
  State<PaperCanvas> createState() => _PaperCanvasState();
}

class _PaperCanvasState extends State<PaperCanvas>
    with SingleTickerProviderStateMixin {
  PaperHandler get handler => widget.handler;
  late final cache = ContentCache(
    textStyle: handler.textStyle,
    files: handler.files,
  );
  late final Ticker _fling;
  FrictionSimulation? _flingX, _flingY;
  Offset _flingLast = Offset.zero;
  Offset? _lastFocal;
  double _lastScale = 1;

  /// True when a stroke blocked this gesture: it ends without momentum.
  bool _blocked = false;

  /// True for a finger gesture while finger navigation is off.
  bool _fingerOff = false;

  @override
  void initState() {
    super.initState();
    _fling = createTicker(_flingTick);
    handler.addListener(_documentChanged);
    handler.files.addListener(_documentChanged);
  }

  @override
  void didUpdateWidget(PaperCanvas old) {
    super.didUpdateWidget(old);
    if (old.handler != handler) {
      old.handler.removeListener(_documentChanged);
      handler.addListener(_documentChanged);
    }
  }

  @override
  void dispose() {
    handler.removeListener(_documentChanged);
    handler.files.removeListener(_documentChanged);
    _fling.dispose();
    cache.dispose();
    super.dispose();
  }

  void _documentChanged() => setState(() {});

  // Navigation ----------------------------------------------------------

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final scroll = e as PointerScrollEvent;
      final keys = HardwareKeyboard.instance;
      if (!keys.isControlPressed &&
          !keys.isMetaPressed &&
          (widget.onWheel?.call(scroll.localPosition, scroll.scrollDelta) ??
              false)) {
        return;
      }
      if (keys.isControlPressed || keys.isMetaPressed) {
        handler.zoomBy(
          math.exp(-scroll.scrollDelta.dy * handler.settings.wheelZoomRate),
          focal: scroll.localPosition,
        );
      } else if (keys.isShiftPressed) {
        handler.scrollBy(Offset(scroll.scrollDelta.dy, scroll.scrollDelta.dx));
      } else {
        handler.scrollBy(scroll.scrollDelta);
      }
    });
  }

  void _scaleStart(ScaleStartDetails d) {
    _fling.stop();
    _fingerOff = d.kind == PointerDeviceKind.touch && !handler.fingerNavigation;
    _lastFocal = d.localFocalPoint;
    _lastScale = 1;
    _blocked = handler.navigationBlocked;
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    if (_fingerOff) return;
    if (handler.navigationBlocked) _blocked = true;
    final last = _lastFocal ?? d.localFocalPoint;
    if (d.scale != _lastScale && d.scale > 0) {
      handler.zoomBy(d.scale / _lastScale, focal: d.localFocalPoint);
      _lastScale = d.scale;
    }
    handler.scrollBy(last - d.localFocalPoint);
    _lastFocal = d.localFocalPoint;
  }

  void _scaleEnd(ScaleEndDetails d) {
    _lastFocal = null;
    final v = d.velocity.pixelsPerSecond;
    if (_fingerOff ||
        d.pointerCount > 1 ||
        v.distance < 50 ||
        handler.navigationBlocked ||
        _blocked) {
      return;
    }
    final friction = handler.settings.flingFriction;
    _flingX = FrictionSimulation(friction, 0, -v.dx);
    _flingY = FrictionSimulation(friction, 0, -v.dy);
    _flingLast = Offset.zero;
    _fling.start();
  }

  void _flingTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    final x = _flingX!, y = _flingY!;
    final now = Offset(x.x(t), y.x(t));
    final moved = handler.scrollBy(now - _flingLast);
    _flingLast = now;
    if (!moved || (x.isDone(t) && y.isDone(t))) _fling.stop();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (widget.onKey?.call(event) == KeyEventResult.handled) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      handler.zoomIn();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      handler.zoomOut();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // Layers --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final paper = PaperColors.of(c);
    cache.update(handler.document, c);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // A new viewport paints at once with its view; the handler takes it
        // after the frame, so no listener changes during layout.
        if (handler.view.value?.size != size) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) handler.layoutView(size);
          });
        }
        return Focus(
          autofocus: true,
          onKeyEvent: _key,
          child: MouseRegion(
            // Draw mode shows a precise pointer over the page.
            cursor: handler.tool == SelectionTool.draw
                ? SystemMouseCursors.precise
                : MouseCursor.defer,
            onHover: (e) => handler.hoverAt(e.localPosition, e.kind),
            onExit: (_) => handler.endHover(),
            child: Listener(
              onPointerDown: (e) {
                handler.pointerDown(e.kind);
                widget.input?.pointerDown(e);
              },
              onPointerMove: widget.input?.pointerMove,
              onPointerUp: widget.input?.pointerUp,
              onPointerCancel: widget.input?.pointerCancel,
              onPointerSignal: _signal,
              child: RawGestureDetector(
                gestures: {
                  ScaleGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        ScaleGestureRecognizer
                      >(
                        () => ScaleGestureRecognizer(
                          supportedDevices: const {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.trackpad,
                          },
                        ),
                        (r) => r
                          ..onStart = _scaleStart
                          ..onUpdate = _scaleUpdate
                          ..onEnd = _scaleEnd,
                      ),
                  TapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        TapGestureRecognizer
                      >(
                        TapGestureRecognizer.new,
                        (r) => r.onTapUp = widget.onTap == null
                            ? null
                            : (d) => widget.onTap!(
                                d.localPosition,
                                d.globalPosition,
                              ),
                      ),
                },
                child: ValueListenableBuilder(
                  valueListenable: handler.view,
                  builder: (context, view, _) => _layers(
                    context,
                    view != null && view.size == size
                        ? view
                        : handler.viewFor(size),
                    paper,
                    c,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _layers(
    BuildContext context,
    PaperView view,
    PaperColors paper,
    AppColors c,
  ) {
    Widget layer(String key, CustomPainter painter) => RepaintBoundary(
      key: Key('paper-layer-$key'),
      child: CustomPaint(painter: painter, size: view.size),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        layer(
          'paper',
          PaperLayerPainter(
            view: view,
            guides: handler.guides,
            width: handler.pageWidth,
            height: handler.pageHeight,
            colors: paper,
            settings: handler.settings,
          ),
        ),
        layer(
          'content',
          ContentLayerPainter(
            view: view,
            cache: cache,
            document: handler.document,
            hidden: handler.editingText,
          ),
        ),
        if (widget.foreground != null) widget.foreground!(context, view),
        // The layers above the foreground only draw; pointers reach the
        // live editor and its message below them.
        IgnorePointer(
          child: layer(
            'active',
            ActiveInkPainter(view: view, ink: handler.activeInk),
          ),
        ),
        IgnorePointer(
          child: layer(
            'frame',
            FrameLayerPainter(
              view: view,
              hover: handler.hover,
              selection: handler.selection,
              pointer: handler.pointer,
              handler: handler,
              cache: cache,
              document: handler.document,
              colors: c,
              settings: handler.settings,
            ),
          ),
        ),
      ],
    );
  }
}
