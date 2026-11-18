/// Point and curve editing of one drawing (annotations#29; B6.3, B6.4, B10).
///
/// Edit points shows the editable nodes of one stroke or path. A node or a
/// handle is dragged on the page; while it moves, the outline shows the
/// proposed path; on release the change is checked by the editor rules and
/// committed as one Undo step. A change that the rules reject (for example a
/// grouped member that would make its group overlap a block) changes nothing
/// and shows the red feedback. Every command also works without dragging:
/// the commands panel and the keyboard.
///
/// Inside a group the member is selected first: with the group selected, a
/// tap on one of its drawings starts point editing of that member.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

import '../../../domain/models/ink.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/note_history.dart';
import '../../../domain/services/object_selection.dart';
import 'draw_handler.dart';
import 'paper_handler.dart';

/// What a pointer drags in point editing.
enum PointPart { node, incoming, outgoing }

class PointEditHandler extends ChangeNotifier implements PaperInput {
  PointEditHandler({required this.draw}) {
    draw.pathEditing.addListener(_targetChanged);
    paper.addListener(_documentChanged);
  }

  final DrawHandler draw;
  PaperHandler get paper => draw.paper;

  /// The stroke or path whose points are edited, or null.
  String? get target => draw.pathEditing.value;
  bool get active => target != null;

  /// The selected node, its handles are shown and the commands act on it.
  int? node;

  /// The last rejected change, shown as the red feedback until the next
  /// accepted change or another command.
  EditorRuleError? rejected;

  /// The proposed nodes while a drag moves; null when nothing is dragged.
  List<InkNode>? preview;

  int? _pointer;
  PointPart? _part;
  int? _dragIndex;
  Offset? _dragStart;
  Offset? _dragAt;

  // Target -----------------------------------------------------------------

  /// The id that Edit points can start with: one selected free stroke or
  /// path, or null.
  String? get selectedTarget {
    final ids = paper.selection.value.ids;
    if (ids.length != 1) return null;
    return isEditable(ids.single) ? ids.single : null;
  }

  /// Whether [id] is a stroke or a path shape: the drawings with nodes.
  bool isEditable(String id) {
    final it = paper.layout?.itemJson(id);
    return it != null &&
        (it['kind'] == 'stroke' ||
            (it['kind'] == 'shape' && it['shape'] == 'path'));
  }

  /// Starts point editing of the stroke or path [id].
  void start(String id) {
    if (!isEditable(id)) return;
    node = null;
    rejected = null;
    draw.pathEditing.value = id;
  }

  /// Ends point editing (Done or Escape). The selection stays.
  void done() {
    _endDrag();
    draw.pathEditing.value = null;
  }

  ObjectSelection? _selectionBefore;

  /// While points are edited, the object frame of the selection is hidden
  /// (the points take its place); Done gives the selection back.
  void _targetChanged() {
    node = null;
    rejected = null;
    _endDrag();
    if (active) {
      _selectionBefore ??= paper.selection.value;
      paper.select(ObjectSelection.empty);
    } else if (_selectionBefore case final before?) {
      _selectionBefore = null;
      paper.select(before);
    }
    notifyListeners();
  }

  void _documentChanged() {
    final id = target;
    if (id == null) return;
    // Undo past the conversion or a deletion ends point editing.
    if (!isEditable(id)) {
      done();
      return;
    }
    final count = nodes.length;
    if (node != null && node! >= count) node = count - 1;
    notifyListeners();
  }

  /// The stored nodes of the target, or the proposed ones during a drag.
  List<InkNode> get nodes => preview ?? storedNodes;

  List<InkNode> get storedNodes {
    final it = target == null ? null : paper.layout?.itemJson(target!);
    return [
      for (final n in (it?['nodes'] as List?) ?? const [])
        InkNode.fromJson((n as Map).cast<String, Object?>()),
    ];
  }

  /// Whether the path is closed (the last node connects to the first).
  bool get closed {
    final it = target == null ? null : paper.layout?.itemJson(target!);
    return it?['closed'] == true;
  }

  // Commands ---------------------------------------------------------------

  /// Selects node [index], or no node with null.
  void selectNode(int? index) {
    node = index;
    rejected = null;
    notifyListeners();
  }

  /// The next or previous node (Tab and Shift Tab).
  void selectNext({bool back = false}) {
    final count = nodes.length;
    if (count == 0) return;
    final i = node;
    selectNode(
      i == null ? (back ? count - 1 : 0) : (i + (back ? count - 1 : 1)) % count,
    );
  }

  /// Moves the selected node by [dx], [dy] page units (arrow keys).
  EditDecision? nudge(num dx, num dy) {
    final i = node;
    if (i == null) return null;
    return _commit((rules, d) => rules.moveNode(d, target!, i, dx, dy));
  }

  /// Adds a node in the middle of the section after the selected node (or
  /// the first section) and selects it. The curve keeps its shape.
  EditDecision? addNode() {
    final count = nodes.length;
    if (count < 2) return null;
    final sections = closed ? count : count - 1;
    final segment = (node ?? 0).clamp(0, sections - 1);
    final d = _commit(
      (rules, doc) => rules.addNode(doc, target!, segment, 0.5),
    );
    if (d != null && d.accepted) node = segment + 1;
    notifyListeners();
    return d;
  }

  /// Removes the selected node. A stroke keeps at least two nodes.
  EditDecision? removeNode() {
    final i = node;
    if (i == null) return null;
    final d = _commit((rules, doc) => rules.removeNode(doc, target!, i));
    if (d != null && d.accepted) {
      node = nodes.isEmpty ? null : (i - 1).clamp(0, nodes.length - 1);
    }
    notifyListeners();
    return d;
  }

  EditDecision? makeCorner() {
    final i = node;
    if (i == null) return null;
    return _commit((rules, d) => rules.makeCorner(d, target!, i));
  }

  EditDecision? makeSmooth() {
    final i = node;
    if (i == null) return null;
    return _commit((rules, d) => rules.makeSmooth(d, target!, i));
  }

  /// The handle mode of the selected node: independent, smooth, symmetric.
  EditDecision? setMode(NodeMode mode) {
    final i = node;
    if (i == null) return null;
    return _commit((rules, d) => rules.setNodeMode(d, target!, i, mode));
  }

  /// One Undo step through the paper history; a rejection keeps the
  /// document and shows the red feedback.
  EditDecision? _commit(
    EditDecision Function(EditorRules rules, NoteDocument document) build,
  ) {
    if (target == null) return null;
    final d = paper.apply(HistoryCommand(CommandKind.points), build);
    rejected = d.accepted ? null : d.error;
    notifyListeners();
    return d;
  }

  // Pointer input ----------------------------------------------------------

  /// The pick radius in page units for the pointer [kind].
  double _radius(PointerDeviceKind kind) {
    final s = paper.settings;
    final screen = kind == PointerDeviceKind.touch
        ? s.touchHandle
        : s.mouseHandle;
    return screen / (paper.view.value?.zoom ?? 1);
  }

  /// The node or handle at [p] (page units) within [radius]: the handles of
  /// the selected node first, then the nodes from the top.
  (PointPart, int)? hit(Offset p, double radius) {
    final list = storedNodes;
    bool near(InkVec v) => (Offset(v.x, v.y) - p).distance <= radius;
    final i = node;
    if (i != null && i < list.length) {
      if (list[i].inPoint case final h? when near(h)) {
        return (PointPart.incoming, i);
      }
      if (list[i].outPoint case final h? when near(h)) {
        return (PointPart.outgoing, i);
      }
    }
    for (var k = list.length - 1; k >= 0; k--) {
      if (near(list[k].point)) return (PointPart.node, k);
    }
    return null;
  }

  Offset? _page(Offset screen) => paper.view.value?.toPage(screen);

  @override
  void pointerDown(PointerDownEvent event) {
    if (!active) {
      if (!_startMember(event)) draw.pointerDown(event);
      return;
    }
    if (_pointer != null) return;
    final p = _page(event.localPosition);
    if (p == null) return;
    final found = hit(p, _radius(event.kind));
    if (found == null) {
      selectNode(null);
      return;
    }
    final (part, index) = found;
    _pointer = event.pointer;
    _part = part;
    _dragIndex = index;
    _dragStart = p;
    _dragAt = p;
    node = index;
    rejected = null;
    notifyListeners();
  }

  /// With one group selected in Draw mode, a tap on one of its drawings
  /// selects that member for point editing (B6.3: the member first).
  bool _startMember(PointerDownEvent event) {
    if (!draw.isDrawMode) return false;
    final layout = paper.layout;
    final ids = paper.selection.value.ids;
    final p = _page(event.localPosition);
    if (layout == null || ids.length != 1 || p == null) return false;
    if (!layout.isGroup(ids.single)) return false;
    final point = InkVec(p.dx, p.dy);
    final radius = _radius(event.kind);
    for (final id in layout.withDescendants(ids.single).reversed) {
      if (isEditable(id) && layout.touches(id, point, radius)) {
        start(id);
        return true;
      }
    }
    return false;
  }

  @override
  void pointerMove(PointerMoveEvent event) {
    if (!active) {
      draw.pointerMove(event);
      return;
    }
    if (event.pointer != _pointer) return;
    final p = _page(event.localPosition);
    if (p == null) return;
    _dragAt = p;
    final d = _dragDecision(paper.session.rules, paper.document);
    final candidate = d?.candidate;
    final item = candidate == null
        ? null
        : (candidate['items'] as List).cast<Map>().firstWhere(
            (it) => it['id'] == target,
            orElse: () => const {},
          );
    preview = item == null || item['nodes'] == null
        ? null
        : [
            for (final n in item['nodes'] as List)
              InkNode.fromJson((n as Map).cast<String, Object?>()),
          ];
    notifyListeners();
  }

  @override
  void pointerUp(PointerUpEvent event) {
    if (!active) {
      draw.pointerUp(event);
      return;
    }
    if (event.pointer != _pointer) return;
    final moved = _dragAt != null && _dragAt != _dragStart;
    if (moved) _commit(_dragDecisionFor);
    _endDrag();
    notifyListeners();
  }

  @override
  void pointerCancel(PointerCancelEvent event) {
    if (!active) {
      draw.pointerCancel(event);
      return;
    }
    if (event.pointer != _pointer) return;
    _endDrag();
    notifyListeners();
  }

  void _endDrag() {
    _pointer = null;
    _part = null;
    _dragIndex = null;
    _dragStart = null;
    _dragAt = null;
    preview = null;
  }

  EditDecision? _dragDecision(EditorRules rules, NoteDocument document) =>
      _part == null ? null : _dragDecisionFor(rules, document);

  /// The change of the current drag: a node moves by the drag delta, a
  /// handle goes to the pointer.
  EditDecision _dragDecisionFor(EditorRules rules, NoteDocument document) {
    final id = target!, i = _dragIndex!, at = _dragAt!, from = _dragStart!;
    return switch (_part!) {
      PointPart.node => rules.moveNode(
        document,
        id,
        i,
        at.dx - from.dx,
        at.dy - from.dy,
      ),
      PointPart.incoming => rules.moveHandle(
        document,
        id,
        i,
        NodeHandle.incoming,
        InkVec(at.dx, at.dy),
      ),
      PointPart.outgoing => rules.moveHandle(
        document,
        id,
        i,
        NodeHandle.outgoing,
        InkVec(at.dx, at.dy),
      ),
    };
  }

  @override
  void dispose() {
    draw.pathEditing.removeListener(_targetChanged);
    paper.removeListener(_documentChanged);
    super.dispose();
  }
}
