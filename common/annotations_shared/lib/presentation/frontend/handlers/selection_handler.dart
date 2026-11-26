/// Selection, move, resize, grouping and the clipboard on the paper
/// (annotations#32, B2.2, B2.5, B2 G1, B3).
///
/// Mouse and pen: a click selects one block, Shift with a click adds or
/// removes one, a drag on empty paper draws a box. A drag on a block moves
/// it (and the selection it is in); a drag on a corner handle resizes the
/// one selected object. A click on a text block still opens it for typing
/// (annotations#27).
///
/// Touch: one finger pans the page. Touch and hold a block selects it, then
/// taps add or remove blocks; touch and hold empty paper, then drag, draws
/// a box. A finger on a selected block or its handle moves or resizes it.
/// A small menu near the selection gives the object actions.
///
/// Draw mode with the selection tool: a tap selects a drawing, a drag on
/// empty paper is a lasso, a drag on a selected drawing moves it.
///
/// While dragging, the proposed position or size shows; the document
/// changes only on release and only when the rules accept it. An invalid
/// drop shows red, and the old position stays. Arrow keys move the
/// selection and the toolbar has size controls, so nothing needs a drag.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

import '../../../core/note_limits.dart';
import '../../../dal/local/local_clipboard_files.dart';
import '../../../dal/local/system_clipboard.dart';
import '../../../domain/models/ink.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/draw_tools.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/note_history.dart';
import '../../../domain/services/object_clipboard.dart';
import '../../../domain/services/object_selection.dart';
import '../components/card_layout.dart';
import '../components/tokens.dart';
import '../../../dal/local/dropped_files.dart';
import '../../../domain/services/card_content.dart';
import 'attachment_handler.dart';
import 'draw_handler.dart';
import 'paper_handler.dart';
import 'text_handler.dart';

/// The proposed place of the dragged objects, in page units.
@immutable
final class SelectionProposal {
  const SelectionProposal(this.frames, {required this.valid});

  /// One rectangle per dragged unit.
  final List<Rect> frames;

  /// False shows red: the drop would be rejected (or was).
  final bool valid;
}

/// A box (two corners) or a lasso (the drawn line), in page units.
@immutable
final class SelectionBand {
  const SelectionBand(this.points, {required this.lasso});
  final List<Offset> points;
  final bool lasso;
}

enum _Press { unit, empty, handle }

class SelectionHandler extends ChangeNotifier implements PaperInput {
  SelectionHandler({
    required this.paper,
    required this.text,
    required this.draw,
    required this.next,
    this.attachments,
    this.confirmRemove,
    ObjectClipboard? clipboard,
    String Function()? newId,
  }) : newId = newId ?? draw.newId {
    _clipboard = clipboard;
    paper.selection.addListener(notifyListeners);
  }

  final PaperHandler paper;
  final TextHandler text;
  final DrawHandler draw;

  /// The tools below: points, then the pens and erasers.
  final PaperInput next;

  /// Files and links (annotations#34): paste of copied files and of a web
  /// link makes cards.
  final AttachmentHandler? attachments;

  /// Asks before pictures, files and links leave the note (B9.5).
  final Future<bool> Function()? confirmRemove;
  final String Function() newId;

  ObjectClipboard? _clipboard;
  ObjectClipboard get clipboard => _clipboard ??= ObjectClipboard(
    system: const FlutterSystemClipboard(),
    files: LocalClipboardFiles(paper.autosave.files),
    engine: text.engine,
    newId: newId,
  );
  late final actions = ObjectActions(newId: newId);

  /// The proposed position or size while dragging, and the red frames of a
  /// rejected drop for a moment.
  final proposal = ValueNotifier<SelectionProposal?>(null);

  /// The selection box or lasso while it is drawn.
  final band = ValueNotifier<SelectionBand?>(null);

  EditorRules get _rules => paper.session.rules;
  NoteDocument get _document => paper.document;
  ObjectSelection get selection => paper.selection.value;

  /// True after a touch and hold selected something: taps add or remove
  /// blocks until a tap on empty paper.
  bool _touchSelecting = false;

  /// The small menu near the selection shows for touch.
  bool get menuShown =>
      selection.isNotEmpty &&
      paper.pointer.value == PointerDeviceKind.touch &&
      !_dragging &&
      paper.editingText == null;

  // Pointer state of the current press.
  int? _pointer;
  PointerDeviceKind _kind = PointerDeviceKind.mouse;
  _Press? _press;
  bool _forwarded = false;
  Offset _downScreen = Offset.zero;
  Offset _downPage = Offset.zero;
  String? _hit;
  bool _shift = false;
  bool _dragging = false;
  bool _held = false;
  bool _suppressTap = false;
  Timer? _hold;
  Offset? _lastPage;

  // Drag state.
  List<String> _ids = const [];
  List<Rect> _frames = const [];
  ResizeAnchor _anchor = ResizeAnchor.topLeft;
  EditDecision? _last;
  Offset _moved = Offset.zero;
  final List<Offset> _lasso = [];
  Timer? _flash;

  SelectionTool get _tool => paper.tool;
  bool get _drawSelect =>
      _tool == SelectionTool.draw && draw.tools.active == DrawTool.select;
  bool get _active => _tool == SelectionTool.type || _drawSelect;

  Offset? _toPage(Offset screen) => paper.view.value?.toPage(screen);

  Rect? _pageRect(String unit) {
    final r = paper.layout?.rectOf(unit);
    if (r == null) return null;
    return Rect.fromLTRB(
      r.left.toDouble(),
      r.top.toDouble(),
      r.right.toDouble(),
      r.bottom.toDouble(),
    );
  }

  String? _hitAt(Offset page) {
    final layout = paper.layout;
    if (layout == null) return null;
    return paper.selector.hitIn(layout, InkVec(page.dx, page.dy), _tool);
  }

  /// The unit of a hit: its outermost group, or itself.
  String? _unitOf(String id) => paper.layout?.unitOf(id);

  /// The corner handle of the one selected unit at [screen], if any.
  ResizeAnchor? _handleAt(Offset screen) {
    if (selection.ids.length != 1) return null;
    final view = paper.view.value;
    final r = _pageRect(selection.ids.first);
    if (view == null || r == null) return null;
    final s = view.rectToScreen(r).inflate(paper.settings.framePadding);
    final touch = _kind == PointerDeviceKind.touch;
    final reach =
        (touch ? paper.settings.touchHandle : paper.settings.mouseHandle) + 6;
    for (final (corner, opposite) in [
      (s.topLeft, ResizeAnchor.bottomRight),
      (s.topRight, ResizeAnchor.bottomLeft),
      (s.bottomLeft, ResizeAnchor.topRight),
      (s.bottomRight, ResizeAnchor.topLeft),
    ]) {
      if ((corner - screen).distance <= reach) return opposite;
    }
    return null;
  }

  bool _insideOpenText(Offset page) {
    final id = paper.editingText;
    if (id == null) return false;
    return _pageRect(id)?.contains(page) ?? false;
  }

  // Pointer input --------------------------------------------------------

  @override
  void pointerDown(PointerDownEvent e) {
    final page = _toPage(e.localPosition);
    if (page != null) _lastPage = page;
    final mouseButton =
        e.kind != PointerDeviceKind.mouse || e.buttons == kPrimaryMouseButton;
    if (_pointer != null ||
        page == null ||
        !_active ||
        !mouseButton ||
        e.kind == PointerDeviceKind.trackpad ||
        e.kind == PointerDeviceKind.invertedStylus ||
        _document is! PaperDocument ||
        _insideOpenText(page)) {
      if (_pointer != null && e.kind == PointerDeviceKind.touch) {
        // A second finger: the selection gesture stops, the fingers navigate.
        _reset();
      }
      _forward(e);
      return;
    }
    _pointer = e.pointer;
    _kind = e.kind;
    _downScreen = e.localPosition;
    _downPage = page;
    _shift = HardwareKeyboard.instance.isShiftPressed;
    _dragging = false;
    _held = false;
    final handle = _handleAt(e.localPosition);
    final hit = handle == null ? _hitAt(page) : null;
    _hit = hit;
    if (handle != null) {
      _press = _Press.handle;
      _anchor = handle;
    } else {
      _press = hit == null ? _Press.empty : _Press.unit;
    }
    if (_kind == PointerDeviceKind.touch) {
      final onSelection =
          handle != null ||
          (hit != null && selection.contains(_unitOf(hit) ?? ''));
      if (onSelection) {
        // A finger on the selection moves or resizes it at once.
        _held = true;
        paper.holding = true;
      } else {
        _hold = Timer(paper.settings.holdDelay, _holdFired);
      }
    }
    notifyListeners();
  }

  void _forward(PointerDownEvent e) {
    _forwarded = true;
    next.pointerDown(e);
  }

  void _holdFired() {
    _hold = null;
    if (_pointer == null || _dragging) return;
    _held = true;
    paper.holding = true;
    _suppressTap = true;
    _touchSelecting = true;
    final hit = _hit;
    if (hit != null) {
      text.end();
      paper.select(paper.selector.toggle(_document, selection, hit));
      if (!selection.contains(_unitOf(hit) ?? '')) {
        // The hold took the block out of the selection: no move follows.
        _press = null;
      }
    }
    HapticFeedback.selectionClick();
    notifyListeners();
  }

  @override
  void pointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) {
      if (_forwarded) next.pointerMove(e);
      return;
    }
    final page = _toPage(e.localPosition);
    if (page == null || _press == null) return;
    _lastPage = page;
    if (!_dragging) {
      final slop = _kind == PointerDeviceKind.touch ? kTouchSlop : 4.0;
      if ((e.localPosition - _downScreen).distance < slop) return;
      _hold?.cancel();
      _hold = null;
      // An unheld finger pans the page.
      if (_kind == PointerDeviceKind.touch && !_held) {
        _reset();
        return;
      }
      _start();
    }
    if (_dragging) _update(page);
  }

  void _start() {
    _dragging = true;
    _suppressTap = true;
    paper.holding = true;
    switch (_press!) {
      case _Press.handle:
        _ids = [selection.ids.first];
      case _Press.unit:
        final unit = _unitOf(_hit!);
        if (unit == null) {
          _press = null;
          return;
        }
        if (!selection.contains(unit)) {
          paper.select(
            _shift
                ? paper.selector.toggle(_document, selection, unit)
                : ObjectSelection([unit]),
          );
        }
        text.end();
        _ids = selection.ids.toList();
      case _Press.empty:
        _lasso
          ..clear()
          ..add(_downPage);
        _ids = const [];
    }
    _frames = [for (final id in _ids) ?_pageRect(id)];
  }

  void _update(Offset page) {
    switch (_press) {
      case _Press.unit:
        final d = page - _downPage;
        _moved = d;
        _last = _rules.move(_document, _ids, d.dx, d.dy);
        final (qx, qy) = _rules.moveDelta(_document, _ids, d.dx, d.dy);
        final shift = Offset(qx.toDouble(), qy.toDouble());
        proposal.value = SelectionProposal([
          for (final f in _frames) f.shift(shift),
        ], valid: _last!.accepted);
      case _Press.handle:
        _resizeTo(page);
      case _Press.empty:
        if (_drawSelect) {
          _lasso.add(page);
          band.value = SelectionBand(List.of(_lasso), lasso: true);
        } else {
          band.value = SelectionBand([_downPage, page], lasso: false);
        }
      case null:
        break;
    }
  }

  /// The resize decision for the one selected unit with its opposite
  /// corner at [_anchor] and the dragged corner at [page].
  void _resizeTo(Offset page) {
    if (_frames.isEmpty) return;
    final f = _frames.first;
    final fixed = switch (_anchor) {
      ResizeAnchor.topLeft => f.topLeft,
      ResizeAnchor.topRight => f.topRight,
      ResizeAnchor.bottomLeft => f.bottomLeft,
      ResizeAnchor.bottomRight => f.bottomRight,
    };
    final width = math.max((page.dx - fixed.dx).abs(), 1.0);
    final height = math.max((page.dy - fixed.dy).abs(), 1.0);
    _last = _resize(_ids.first, width, height, _anchor);
    proposal.value = SelectionProposal([
      _proposedRect(_last!, _ids.first, fixed, width, height, f),
    ], valid: _last!.accepted);
  }

  EditDecision _resize(
    String id,
    double width,
    double height,
    ResizeAnchor anchor,
  ) {
    final layout = paper.layout;
    final kind = layout?.kindOf(id);
    num? measured;
    final document = _document;
    if (document is PaperDocument) {
      final it = document.itemsJson.firstWhere((i) => i['id'] == id);
      if (kind == 'text') {
        measured = text.engine.measureHeight(
          (it['spans'] as List?) ?? const [],
          EditorGrid.round(width),
        );
      } else {
        // A card whose text wraps takes its measured height (annotations#34).
        measured = measureCard(
          it,
          EditorGrid.round(width).toDouble(),
          CardStyle(text: paper.textStyle, colors: AppColors.light),
          paper.files,
        );
      }
    }
    return _rules.resize(
      _document,
      id,
      width: width,
      height: EditorGrid.areaKinds.contains(kind) ? height : null,
      anchor: anchor,
      measuredHeight: measured,
      effectiveFontSize: (_, _) => paper.textStyle.fontSize,
    );
  }

  /// The rectangle to show for a resize: the result when accepted, else the
  /// requested size with the shape of the object.
  Rect _proposedRect(
    EditDecision d,
    String id,
    Offset fixed,
    double width,
    double height,
    Rect from,
  ) {
    if (d.accepted) {
      final r = DocumentLayout.of(d.document)?.rectOf(id);
      if (r != null) {
        return Rect.fromLTRB(
          r.left.toDouble(),
          r.top.toDouble(),
          r.right.toDouble(),
          r.bottom.toDouble(),
        );
      }
    }
    final h = from.width > 0 ? width * from.height / from.width : height;
    final left = fixed.dx == from.left ? fixed.dx : fixed.dx - width;
    final top = fixed.dy == from.top ? fixed.dy : fixed.dy - h;
    return Rect.fromLTWH(left, top, width, h);
  }

  @override
  void pointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) {
      if (_forwarded) next.pointerUp(e);
      _forwarded = false;
      return;
    }
    if (_dragging) {
      _drop(_toPage(e.localPosition) ?? _downPage);
    } else if (_drawSelect && !_held) {
      // A tap with the selection tool in Draw mode.
      _drawTap();
    }
    _reset(keepProposal: true);
  }

  @override
  void pointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) {
      if (_forwarded) next.pointerCancel(e);
      _forwarded = false;
      return;
    }
    proposal.value = null;
    _reset();
  }

  void _reset({bool keepProposal = false}) {
    _hold?.cancel();
    _hold = null;
    _pointer = null;
    _press = null;
    _dragging = false;
    _held = false;
    _ids = const [];
    _frames = const [];
    _last = null;
    band.value = null;
    if (!keepProposal) proposal.value = null;
    paper.holding = false;
    notifyListeners();
  }

  void _drop(Offset page) {
    switch (_press) {
      case _Press.unit:
        final d = _moved;
        final ids = _ids;
        if (_last?.accepted ?? false) {
          proposal.value = null;
          paper.apply(
            HistoryCommand(CommandKind.move),
            (rules, document) => rules.move(document, ids, d.dx, d.dy),
          );
        } else {
          _rejected(proposal.value?.frames);
        }
      case _Press.handle:
        final last = _last;
        if (last != null && last.accepted) {
          proposal.value = null;
          paper.apply(HistoryCommand(CommandKind.resize), (_, _) => last);
        } else {
          _rejected(proposal.value?.frames);
        }
      case _Press.empty:
        final band = this.band.value;
        if (band == null) break;
        if (band.lasso) {
          paper.select(
            paper.selector.lasso(_document, [
              for (final p in band.points) InkVec(p.dx, p.dy),
            ], addTo: _shift ? selection : null),
          );
        } else {
          final [a, b] = band.points;
          text.end();
          paper.select(
            paper.selector.box(
              _document,
              InkVec(a.dx, a.dy),
              InkVec(b.dx, b.dy),
              tool: _tool,
              addTo: _shift ? selection : null,
            ),
          );
        }
      case null:
        break;
    }
  }

  /// Shows [frames] red for a moment; the stored document did not change.
  void _rejected(List<Rect>? frames) {
    final shown = frames ?? [for (final id in selection.ids) ?_pageRect(id)];
    proposal.value = SelectionProposal(shown, valid: false);
    _flash?.cancel();
    _flash = Timer(paper.settings.rejectedDrop, () => proposal.value = null);
  }

  void _drawTap() {
    final hit = _hit;
    if (hit == null) {
      paper.select(ObjectSelection.empty);
    } else if (_shift) {
      paper.select(paper.selector.toggle(_document, selection, hit));
    } else {
      paper.select(paper.selector.select(_document, hit));
    }
  }

  /// A click or tap on the page that no editor took (Type mode). It selects
  /// a block, adds or removes one with Shift (or after a touch and hold),
  /// clears the selection on empty paper, and otherwise opens or starts a
  /// text block like before (annotations#27).
  void tap(Offset local, Offset global) {
    if (_suppressTap) {
      _suppressTap = false;
      return;
    }
    if (_tool != SelectionTool.type) return;
    final page = _toPage(local);
    if (page == null) return;
    final hit = _hitAt(page);
    final touch = paper.pointer.value == PointerDeviceKind.touch;
    final adding = (!touch && _shift) || (touch && _touchSelecting);
    if (adding) {
      if (hit != null) {
        text.end();
        paper.select(paper.selector.toggle(_document, selection, hit));
        if (selection.isEmpty) _touchSelecting = false;
      } else {
        _touchSelecting = false;
        paper.select(ObjectSelection.empty);
      }
      return;
    }
    if (hit != null && !_opensText(hit)) {
      text.end();
      paper.select(paper.selector.select(_document, hit));
      return;
    }
    if (hit == null && selection.isNotEmpty) {
      paper.select(ObjectSelection.empty);
      return;
    }
    paper.select(ObjectSelection.empty);
    text.tapAt(local, global: global);
  }

  /// A click on [id] opens it for typing: a text block on its own, or a
  /// text member of a group that is already selected (B3.3).
  bool _opensText(String id) {
    final layout = paper.layout;
    if (layout?.kindOf(id) != 'text') return false;
    final unit = _unitOf(id);
    return unit == id || selection.contains(unit ?? '');
  }

  // Keyboard ---------------------------------------------------------------

  /// The shortcuts of the page while no text block has the focus.
  KeyEventResult key(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final command = keys.isControlPressed || keys.isMetaPressed;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    bool done(void Function() action) {
      action();
      return true;
    }

    final handled = switch (key) {
      LogicalKeyboardKey.keyA when command => done(selectAll),
      LogicalKeyboardKey.keyC when command && !repeat => done(copy),
      LogicalKeyboardKey.keyX when command && !repeat => done(cut),
      LogicalKeyboardKey.keyV when command && !repeat => done(paste),
      LogicalKeyboardKey.keyD when command => done(duplicate),
      LogicalKeyboardKey.keyG when command && keys.isShiftPressed => done(
        ungroup,
      ),
      LogicalKeyboardKey.keyG when command => done(group),
      LogicalKeyboardKey.keyZ when command && keys.isShiftPressed => done(
        paper.redo,
      ),
      LogicalKeyboardKey.keyZ when command => done(paper.undo),
      LogicalKeyboardKey.keyY when command => done(paper.redo),
      LogicalKeyboardKey.delete ||
      LogicalKeyboardKey.backspace when selection.isNotEmpty => done(delete),
      LogicalKeyboardKey.escape when selection.isNotEmpty => done(clear),
      LogicalKeyboardKey.arrowLeft ||
      LogicalKeyboardKey.arrowRight ||
      LogicalKeyboardKey.arrowUp ||
      LogicalKeyboardKey.arrowDown when selection.isNotEmpty && !command =>
        done(() => _arrow(key, keys.isShiftPressed)),
      _ => false,
    };
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _arrow(LogicalKeyboardKey key, bool big) {
    final (x, y) = switch (key) {
      LogicalKeyboardKey.arrowLeft => (-1, 0),
      LogicalKeyboardKey.arrowRight => (1, 0),
      LogicalKeyboardKey.arrowUp => (0, -1),
      _ => (0, 1),
    };
    nudge(x, y, big: big);
  }

  // Actions ------------------------------------------------------------------

  void clear() {
    _touchSelecting = false;
    paper.select(ObjectSelection.empty);
  }

  void selectAll() {
    text.end();
    paper.select(paper.selector.all(_document, tool: _tool));
  }

  void _done(ObjectEdit edit) {
    if (edit.accepted) {
      paper.edited();
      paper.select(edit.selection);
    } else if (edit.error != null) {
      _rejected(null);
    }
  }

  Future<void> copy() async {
    if (selection.isEmpty) return;
    await clipboard.copy(paper.session, selection);
  }

  Future<void> cut() async {
    if (selection.isEmpty) return;
    _done(await clipboard.cut(paper.session, selection));
  }

  /// Pastes at the last pointer position on the page, or near the top of
  /// the visible page.
  Future<void> paste() async {
    final view = paper.view.value;
    final at =
        _lastPage ??
        (view == null
            ? Offset.zero
            : view.visiblePage.topLeft + const Offset(24, 24));
    text.end();
    if (attachments case final files?) {
      // Files copied in a file manager, then one web link as a link card.
      final paths = await clipboardFilePaths();
      if (paths.isNotEmpty) {
        await files.drop(paths, const [], at);
        return;
      }
      final link = webLink(await clipboard.system.readText() ?? '');
      if (link != null &&
          clipboard.content == null &&
          await files.addLink(link, at: at)) {
        return;
      }
    }
    _done(
      await clipboard.paste(paper.session, InkVec(at.dx, at.dy), selection),
    );
  }

  void duplicate() {
    if (selection.isEmpty) return;
    _done(actions.duplicate(paper.session, selection));
  }

  Future<void> delete() async {
    if (selection.isEmpty) return;
    final ids = selection;
    final layout = paper.layout;
    final cards = ids.ids.any(
      (id) => (layout?.withDescendants(id) ?? const <String>[]).any(
        (m) => isCardKind(layout?.kindOf(m)),
      ),
    );
    if (cards && confirmRemove != null && !await confirmRemove!()) return;
    _done(actions.delete(paper.session, ids));
  }

  bool get canGroup => selection.ids.length >= 2;
  bool get canUngroup =>
      selection.ids.any((id) => paper.layout?.isGroup(id) ?? false);

  void group() {
    if (!canGroup) return;
    _done(actions.group(paper.session, selection));
  }

  void ungroup() {
    if (!canUngroup) return;
    _done(actions.ungroup(paper.session, selection));
  }

  /// Moves the selection by whole grid cells: the move without a drag.
  void nudge(int x, int y, {bool big = false}) {
    if (selection.isEmpty) return;
    final cells = big
        ? paper.settings.bigNudgeCells
        : paper.settings.nudgeCells;
    final step = (cells * EditorGrid.cell).toDouble();
    final ids = selection.ids.toList();
    final d = paper.apply(
      HistoryCommand(CommandKind.move),
      (rules, document) => rules.move(document, ids, x * step, y * step),
    );
    if (!d.accepted) _rejected(null);
  }

  /// The one selected unit, for the size controls.
  String? get sizeTarget =>
      selection.ids.length == 1 ? selection.ids.first : null;

  /// Makes the one selected object one grid cell wider ([cells] > 0) or
  /// narrower: the resize without a drag. The top left corner stays.
  void resizeBy(int cells) {
    final id = sizeTarget;
    final r = id == null ? null : _pageRect(id);
    if (id == null || r == null) return;
    final width = math.max(r.width + cells * EditorGrid.cell, 1.0);
    final height = r.width > 0 ? r.height * width / r.width : r.height;
    final decision = _resize(id, width, height, ResizeAnchor.topLeft);
    if (decision.accepted) {
      paper.apply(HistoryCommand(CommandKind.resize), (_, _) => decision);
    } else {
      _rejected([Rect.fromLTWH(r.left, r.top, width, height)]);
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _flash?.cancel();
    paper.selection.removeListener(notifyListeners);
    proposal.dispose();
    band.dispose();
    super.dispose();
  }
}
