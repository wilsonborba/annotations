/// The flow of Type and Draw modes and of the drawing tools on the paper
/// canvas (annotations#28; B5, B6.1, B6.2, B6.4, B8).
///
/// The widgets call this handler; the handler calls the domain: the stroke
/// capture and the shape builders for new ink, the editor rules for every
/// committed stroke, shape, restyle and Edit as path (each one history step
/// through [PaperHandler.apply]), and the preferences for the remembered tool
/// settings and the finger drawing option.
///
/// Input in Draw mode: a pen and the primary mouse button draw. A finger
/// draws only when finger drawing is on (B8, off at first); a second finger
/// cancels that stroke and the two fingers navigate. The eraser end of a pen
/// (annotations#30) and a trackpad never draw. Pressure comes only from a
/// pen that reports a pressure range; a mouse has none, so its strokes have
/// the fixed width of the tool (B6.1, B10.6).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../../../core/draw_settings.dart';
import '../../../domain/models/ink.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/draw_tools.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/ink_eraser.dart';
import '../../../domain/services/ink_outline.dart';
import '../../../domain/services/note_history.dart';
import '../../../domain/services/object_selection.dart';
import '../../../domain/services/preferences.dart';
import 'paper_handler.dart';

/// Pointer input of the paper canvas. The canvas forwards every pointer
/// event of the page; the receiver decides what draws.
abstract interface class PaperInput {
  void pointerDown(PointerDownEvent event);
  void pointerMove(PointerMoveEvent event);
  void pointerUp(PointerUpEvent event);
  void pointerCancel(PointerCancelEvent event);
}

class DrawHandler extends ChangeNotifier implements PaperInput {
  DrawHandler({
    required this.paper,
    required this.preferences,
    this.settings = const DrawSettings(),
    this.onDrawMode,
    String Function()? newId,
  }) : newId = newId ?? _randomId,
       _tools = preferences.drawTools {
    paper.selection.addListener(_selectionChanged);
  }

  final PaperHandler paper;
  final Preferences preferences;
  final DrawSettings settings;
  final String Function() newId;

  /// Runs before Draw mode starts: the open text block closes, so ink over
  /// text never meets a text cursor (B5).
  final VoidCallback? onDrawMode;

  DrawTools _tools;

  /// The active tool and the settings that each tool remembers.
  DrawTools get tools => _tools;

  /// The shape that Edit as path just converted: the hand-over to point
  /// editing (annotations#29), which shows its points.
  final pathEditing = ValueNotifier<String?>(null);

  // Mode -----------------------------------------------------------------

  SelectionTool get mode => paper.tool;
  bool get isDrawMode => mode == SelectionTool.draw;

  /// Switches between Type and Draw. Content, selection and history stay;
  /// nothing starts recognition (B5). A stroke in progress is cancelled
  /// first, so no gesture is left open (B8).
  void setMode(SelectionTool value) {
    if (value == mode) return;
    cancel();
    // Leaving Draw mode leaves the eraser too.
    _dangerous = false;
    if (value == SelectionTool.draw) onDrawMode?.call();
    paper.tool = value;
    notifyListeners();
  }

  // Tools and settings ---------------------------------------------------

  void selectTool(DrawTool tool) {
    if (tool == _tools.active) return;
    // Delete anything turns off when the user leaves the eraser (B2.6).
    if (tool != DrawTool.eraser) _dangerous = false;
    _tools = _tools.withActive(tool);
    preferences.saveDrawTools(_tools);
    notifyListeners();
  }

  void selectShape(ShapeKind kind) {
    _tools = _tools.withShapeKind(kind);
    preferences.saveDrawTools(_tools);
    notifyListeners();
  }

  // Eraser -----------------------------------------------------------------

  bool _dangerous = false;

  /// Delete-anything mode of the eraser (B2.6): off at first, never kept on
  /// this device, and off again when the user leaves the eraser.
  bool get dangerous => _dangerous;

  /// Turns delete-anything on or off. Turning it on selects the eraser and
  /// shows the warning ([dangerWarning]).
  void setDangerous(bool on) {
    _dangerous = on;
    dangerWarning = on;
    if (on && _tools.active != DrawTool.eraser) {
      _tools = _tools.withActive(DrawTool.eraser);
      preferences.saveDrawTools(_tools);
    }
    notifyListeners();
  }

  /// True after delete-anything was turned on, until the warning is closed.
  bool dangerWarning = false;

  void closeDangerWarning() {
    dangerWarning = false;
    notifyListeners();
  }

  /// Sets the normal eraser mode or size; the device remembers them.
  void setEraser({EraserMode? mode, num? radius, bool done = true}) {
    _tools = _tools.withEraser(
      _tools.eraser.copyWith(mode: mode, radius: radius),
    );
    if (done) preferences.saveDrawTools(_tools);
    notifyListeners();
  }

  /// The eraser circle while erasing: center and radius in page units.
  final eraserAt = ValueNotifier<(InkVec, double)?>(null);

  InkEraseGesture? _erase;
  NoteDocument? _eraseStart;
  InkVec? _eraseLast;
  bool _eraseDangerous = false;

  bool get isErasing => _erase != null || _eraseStart != null;

  void _beginErase(PointerDownEvent e, InkVec p) {
    // The eraser end of a pen erases with the normal eraser; delete anything
    // needs the eraser tool itself.
    _eraseDangerous = _dangerous && _tools.active == DrawTool.eraser;
    final radius = _tools.eraser.radius.toDouble();
    eraserAt.value = (p, radius);
    // An empty mark blocks page navigation while the eraser is down.
    paper.activeInk.value = const InkOutline([], '#00000000', 1);
    final session = paper.session;
    if (session is NotesEditor) {
      _erase = InkEraseGesture.begin(
        session,
        at: p,
        radius: radius,
        mode: _tools.eraser.mode,
        dangerous: _eraseDangerous,
        newId: newId,
        settings: paper.selector.ink,
      );
      paper.edited();
    } else {
      _eraseStart = paper.document;
      _eraseLast = p;
      _instantErase(p);
    }
  }

  void _moveErase(InkVec p) {
    eraserAt.value = (p, eraserAt.value?.$2 ?? _tools.eraser.radius.toDouble());
    if (_erase case final gesture?) {
      if (gesture.moveTo(p).accepted) paper.edited();
    } else if (_eraseStart != null) {
      _instantErase(p);
    }
  }

  /// Instant has no history: each move is erased live; a cancel puts back
  /// the room document of the gesture start.
  void _instantErase(InkVec to) {
    final from = _eraseLast ?? to, start = _eraseStart!;
    _eraseLast = to;
    final radius = _tools.eraser.radius.toDouble();
    paper.apply(
      HistoryCommand(CommandKind.erase),
      (rules, document) => _eraseDangerous
          ? rules.eraseObjects(
              document,
              start: start,
              from: from,
              to: to,
              radius: radius,
              settings: paper.selector.ink,
            )
          : rules.erase(
              document,
              from: from,
              to: to,
              radius: radius,
              mode: _tools.eraser.mode,
              newId: newId,
              settings: paper.selector.ink,
            ),
    );
  }

  void _endErase({required bool cancelled}) {
    if (_erase case final gesture?) {
      cancelled ? gesture.cancel() : gesture.end();
      paper.edited();
    } else if (_eraseStart case final start? when cancelled) {
      paper.apply(
        HistoryCommand(CommandKind.erase),
        (rules, _) => rules.check(start),
      );
    }
    _erase = null;
    _eraseStart = null;
    _eraseLast = null;
    eraserAt.value = null;
  }

  /// The stroke and shape items that a setting change reaches now.
  List<String> get selectedInkIds {
    final layout = paper.layout;
    if (layout == null) return const [];
    return selectedInk(layout, paper.selection.value);
  }

  /// True when a setting change goes to the selected ink, not to the tool.
  bool get editsSelection => selectedInkIds.isNotEmpty;

  InkStyleChange? _pending;

  /// The values of the settings panel: the selected ink, else the active
  /// tool, with a value that is still changing.
  InkStyle get style {
    final ids = selectedInkIds;
    final layout = paper.layout;
    final base =
        (ids.isEmpty || layout == null
            ? null
            : inkStyleOf(layout, ids.first)) ??
        _tools.styleOf(_tools.active);
    final pending = _pending;
    return pending == null ? base : base.apply(pending);
  }

  /// Whether the panel shows the tip angle: the flat pen, or selected flat
  /// pen strokes.
  bool get showsTipAngle {
    final ids = selectedInkIds;
    if (ids.isEmpty) return _tools.active == DrawTool.flat;
    return _flatStrokes(ids).isNotEmpty;
  }

  /// The largest width of the width control: the highlighter goes wider.
  num get maxWidth {
    final ids = selectedInkIds;
    final layout = paper.layout;
    final highlighter = ids.isEmpty
        ? _tools.active == DrawTool.highlighter
        : ids.any((id) => layout?.itemJson(id)?['tool'] == 'highlighter');
    return highlighter ? settings.maxHighlighterWidth : settings.maxWidth;
  }

  /// Changes a setting (B6.2). Without selected ink it changes the active
  /// tool for future strokes. With selected ink it changes only those items,
  /// as one history step, and the tool keeps its settings. [done] false is a
  /// value that is still changing (a slider drag): it is shown, not applied.
  void change(InkStyleChange value, {bool done = true}) {
    final ids = selectedInkIds;
    if (ids.isEmpty) {
      _pending = null;
      _tools = _tools.changed(_tools.active, value);
      if (done) preferences.saveDrawTools(_tools);
      notifyListeners();
      return;
    }
    if (!done) {
      _pending = value;
      notifyListeners();
      return;
    }
    _pending = null;
    final angle = value.tipAngle;
    final targets = angle == null ? ids : _flatStrokes(ids);
    if (targets.isNotEmpty) {
      paper.apply(
        HistoryCommand(CommandKind.ink),
        (rules, document) => rules.restyleInk(
          document,
          targets,
          width: value.width,
          color: value.color,
          opacity: value.opacity,
          tipAngle: angle,
        ),
      );
    }
    notifyListeners();
  }

  List<String> _flatStrokes(List<String> ids) {
    final layout = paper.layout;
    return [
      for (final id in ids)
        if (layout?.itemJson(id)?['tool'] == 'flat') id,
    ];
  }

  void _selectionChanged() {
    _pending = null;
    notifyListeners();
  }

  /// The shape of the panel preview: the kind of the first selected shape,
  /// else the kind of new shapes.
  ShapeKind get previewShape {
    final ids = selectedInkIds;
    final layout = paper.layout;
    final kind = ids.isEmpty
        ? null
        : ShapeKind.parse(layout?.itemJson(ids.first)?['shape']);
    return kind ?? _tools.shape.kind;
  }

  /// The selected strokes that Apply pen style reaches: strokes only,
  /// because shapes have no pen.
  List<String> get selectedStrokeIds {
    final layout = paper.layout;
    return [
      for (final id in selectedInkIds)
        if (layout?.kindOf(id) == 'stroke') id,
    ];
  }

  /// Apply pen style (B6.2): the explicit action that reshapes the selected
  /// strokes with the pen [tool] and its current settings, as one history
  /// step. Nothing else reshapes an existing line. Null when no stroke is
  /// selected or [tool] is not a pen.
  EditDecision? applyPenStyle(DrawTool tool) {
    final pen = tool.pen;
    final ids = selectedStrokeIds;
    if (pen == null || ids.isEmpty) return null;
    final decision = paper.apply(
      HistoryCommand(CommandKind.ink),
      (rules, document) => rules.applyBrush(document, ids, _tools.pen(pen)),
    );
    notifyListeners();
    return decision;
  }

  /// The one selected circle, triangle or rectangle, or null.
  String? get pathTarget {
    final ids = paper.selection.value.ids;
    final layout = paper.layout;
    if (ids.length != 1 || layout == null) return null;
    return isGeometricShape(layout, ids.single) ? ids.single : null;
  }

  /// Edit as path (B6.4): the selected shape becomes a path with the same
  /// look, as one history step, and point editing takes it over.
  EditDecision? editAsPath() {
    final id = pathTarget;
    if (id == null) return null;
    final decision = paper.apply(
      HistoryCommand(CommandKind.points),
      (rules, document) => rules.editAsPath(document, id),
    );
    if (decision.accepted) pathEditing.value = id;
    notifyListeners();
    return decision;
  }

  // Pointer input --------------------------------------------------------

  int? _pointer;
  PointerDeviceKind? _kind;
  StrokeCapture? _capture;
  InkVec? _shapeStart;
  JsonObject? _shape;
  final _touches = <int>{};

  /// True while a stroke or a shape is drawn.
  bool get isDrawing => _pointer != null;

  bool _accepts(PointerDownEvent e) => switch (e.kind) {
    PointerDeviceKind.stylus => true,
    PointerDeviceKind.mouse => e.buttons == kPrimaryMouseButton,
    PointerDeviceKind.touch => preferences.fingerDrawing,
    // The eraser end belongs to the erasers; a trackpad navigates.
    _ => false,
  };

  @override
  void pointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.touch) _touches.add(e.pointer);
    if (_pointer != null) {
      // A second finger: the stroke of the first one stops and the two
      // fingers navigate (B8).
      if (e.kind == PointerDeviceKind.touch &&
          _kind == PointerDeviceKind.touch) {
        cancel();
      }
      return;
    }
    final erasing =
        e.kind == PointerDeviceKind.invertedStylus ||
        (_tools.active == DrawTool.eraser && _accepts(e));
    // The selection tool selects the drawing under the pointer (B7 rule 3);
    // selecting is not drawing, so a finger selects even with finger drawing
    // off. Box and lasso gestures come with annotations#32.
    if (isDrawMode &&
        _pointer == null &&
        _tools.active == DrawTool.select &&
        e.kind != PointerDeviceKind.trackpad &&
        (e.kind != PointerDeviceKind.mouse ||
            e.buttons == kPrimaryMouseButton)) {
      final p = _page(e.localPosition);
      if (p == null || paper.document is! PaperDocument) return;
      final hit = paper.selector.hit(paper.document, p, SelectionTool.draw);
      paper.select(
        hit == null ? ObjectSelection.empty : ObjectSelection([hit]),
      );
      notifyListeners();
      return;
    }
    if (!isDrawMode || !(erasing || _accepts(e)) || _touches.length > 1) {
      return;
    }
    if (paper.document is! PaperDocument) return;
    final p = _page(e.localPosition);
    if (p == null) return;
    _pointer = e.pointer;
    _kind = e.kind;
    if (paper.selection.value.isNotEmpty) {
      paper.select(ObjectSelection.empty);
    }
    if (erasing) {
      _beginErase(e, p);
      return;
    }
    final pen = _tools.active.pen;
    if (pen == null) {
      _shapeStart = p;
      _shape = null;
      // An empty mark blocks page navigation from the first contact.
      paper.activeInk.value = const InkOutline([], '#00000000', 1);
      return;
    }
    _capture = _newCapture(pen);
    _add(e, p);
  }

  @override
  void pointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final p = _page(e.localPosition);
    if (p == null) return;
    if (isErasing) {
      _moveErase(p);
    } else if (_capture != null) {
      _add(e, p);
    } else if (_shapeStart != null) {
      _previewShape(p);
    }
  }

  @override
  void pointerUp(PointerUpEvent e) {
    _touches.remove(e.pointer);
    if (e.pointer != _pointer) return;
    if (isErasing) {
      _endErase(cancelled: false);
      _reset();
      return;
    }
    final capture = _capture;
    if (capture != null) {
      _commitStroke(capture);
    } else if (_shape != null) {
      final shape = _shape!;
      paper.apply(
        HistoryCommand(CommandKind.ink),
        (rules, document) => rules.addInk(document, shape),
      );
    }
    _reset();
  }

  @override
  void pointerCancel(PointerCancelEvent e) {
    _touches.remove(e.pointer);
    if (e.pointer == _pointer) cancel();
  }

  /// Drops the stroke or shape in progress without a history step.
  void cancel() {
    if (_pointer == null) return;
    if (isErasing) _endErase(cancelled: true);
    _reset();
  }

  void _reset() {
    _pointer = null;
    _kind = null;
    _capture = null;
    _shapeStart = null;
    _shape = null;
    paper.activeInk.value = null;
  }

  InkVec? _page(Offset local) {
    final view = paper.view.value;
    if (view == null) return null;
    final p = view.toPage(local);
    return InkVec(p.dx, p.dy);
  }

  StrokeCapture _newCapture(InkTool pen) => StrokeCapture(
    _tools.pen(pen),
    pageWidth: paper.pageWidth,
    limits: paper.session.rules.limits,
  );

  void _add(PointerEvent e, InkVec p) {
    var capture = _capture!;
    final time = e.timeStamp.inMilliseconds;
    final pressure = _pressure(e), tilt = _tilt(e);
    if (!capture.add(p.x, p.y, time, pressure: pressure, tilt: tilt)) {
      // A full stroke ends and the line continues as a new stroke.
      _commitStroke(capture);
      capture = _capture = _newCapture(capture.brush.tool);
      capture.add(p.x, p.y, time, pressure: pressure, tilt: tilt);
    }
    final preview = capture.toPreviewItem();
    if (preview == null) return;
    final item = DocumentItem.fromJson(
      preview,
      family: DocumentFamily.original,
    );
    paper.activeInk.value = item is StrokeItem
        ? strokeOutline(item, settings: paper.selector.ink)
        : null;
  }

  void _commitStroke(StrokeCapture capture) {
    final item = capture.toItem(newId(), settings: paper.selector.ink);
    if (item == null) return;
    paper.apply(
      HistoryCommand(CommandKind.ink),
      (rules, document) => rules.addInk(document, item),
    );
  }

  void _previewShape(InkVec p) {
    final start = _shapeStart!;
    final width = paper.pageWidth;
    InkVec clamp(InkVec v) =>
        InkVec(v.x.clamp(0, width), math.max(0, v.y).toDouble());
    final shape = _shape = shapeFromDrag(
      _shape?['id'] as String? ?? newId(),
      _tools.shape.kind,
      clamp(start),
      clamp(p),
      _tools.shape.style,
      minSize: settings.minShapeSize,
    );
    final item = shape == null
        ? null
        : DocumentItem.fromJson(shape, family: DocumentFamily.original);
    paper.activeInk.value = item is ShapeItem
        ? shapeOutline(item, settings: paper.selector.ink)?.line
        : const InkOutline([], '#00000000', 1);
  }

  /// Device pressure from 0 to 1, only from a pen that reports a range.
  /// Nothing is made up from speed (B6.1).
  static double? _pressure(PointerEvent e) {
    if (e.kind != PointerDeviceKind.stylus) return null;
    final range = e.pressureMax - e.pressureMin;
    if (range <= 0) return null;
    return ((e.pressure - e.pressureMin) / range).clamp(0.0, 1.0);
  }

  /// Pen tilt in radians as the device reports it.
  static double? _tilt(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ? e.tilt : null;

  @override
  void dispose() {
    paper.selection.removeListener(_selectionChanged);
    pathEditing.dispose();
    eraserAt.dispose();
    super.dispose();
  }
}

final _random = math.Random.secure();

String _randomId() =>
    'ink-${List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join()}';
