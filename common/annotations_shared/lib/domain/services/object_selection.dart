/// Object selection on the page (B2 G1, confirmed by the owner): one block,
/// add or remove with a modifier, a box on empty paper, select all, and a lasso
/// for drawing in Draw mode. Mouse, keyboard, touch and pen all use these same
/// functions; this file has no gesture code.
///
/// The selection holds top-level units: a free item or its outermost group. A
/// click on a member of a group selects the whole group (B2.5: a group acts as
/// one object). Text selection inside a text block is a different thing: it
/// belongs to the text engine, and [EditorFocus] keeps the two apart, so the
/// page never has selected objects and a text caret at the same time.
library;

import '../../core/ink_settings.dart';
import '../../core/selection_settings.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'ink_geometry.dart';

/// The tool that the selection gesture comes from. Type mode reaches text
/// and cards under ink first; Draw mode selects only drawing (B2.4).
enum SelectionTool { type, draw }

/// Selected top-level units. Immutable; the order is the order of selection.
final class ObjectSelection {
  ObjectSelection([Iterable<String> ids = const []])
    : ids = List.unmodifiable(ids.toSet());

  static final empty = ObjectSelection();

  final List<String> ids;
  bool get isEmpty => ids.isEmpty;
  bool get isNotEmpty => ids.isNotEmpty;
  bool contains(String id) => ids.contains(id);

  /// The selected units in document order.
  List<String> inDocumentOrder(DocumentLayout layout) => [
    for (final id in layout.units)
      if (ids.contains(id)) id,
  ];

  @override
  bool operator ==(Object other) =>
      other is ObjectSelection &&
      other.ids.length == ids.length &&
      other.ids.every(ids.contains);

  @override
  int get hashCode => Object.hashAllUnordered(ids);

  @override
  String toString() => 'ObjectSelection(${ids.length} units)';
}

/// What the page has in focus: nothing, selected objects, or the text of one
/// text block. One value is never both, so object actions (copy of objects,
/// group, delete of objects) and text actions (copy of selected text, typing)
/// never mix. The text selection itself lives in the text engine.
sealed class EditorFocus {
  const EditorFocus();
}

final class NoFocus extends EditorFocus {
  const NoFocus();
}

final class ObjectFocus extends EditorFocus {
  const ObjectFocus(this.selection);
  final ObjectSelection selection;
}

/// The text engine edits the text item [itemId]; its own selection and its
/// own clipboard paths apply (annotations#23).
final class TextFocus extends EditorFocus {
  const TextFocus(this.itemId);
  final String itemId;
}

/// Selection geometry. Every function returns a new selection; none of them
/// changes the document or creates a history step.
final class ObjectSelector {
  const ObjectSelector({
    this.settings = const SelectionSettings(),
    this.ink = const InkSettings(),
  });
  final SelectionSettings settings;
  final InkSettings ink;

  /// The unit at [point], or null for empty paper. Type mode takes the top
  /// structured block first (text under ink stays reachable), then the top
  /// drawing. Draw mode takes only units that are drawing.
  String? hit(NoteDocument document, InkVec point, SelectionTool tool) {
    final layout = DocumentLayout.of(document);
    return layout == null ? null : hitIn(layout, point, tool);
  }

  /// [hit] in a [DocumentLayout] that the caller keeps for one document
  /// state, so that pointer hover does not build the layout again on every
  /// move (annotations#26).
  String? hitIn(DocumentLayout layout, InkVec point, SelectionTool tool) {
    final ids = layout.ids.reversed.toList();
    if (tool == SelectionTool.type) {
      for (final id in ids) {
        if (_isLeafBlock(layout, id) && layout.touches(id, point, 0)) {
          return layout.unitOf(id);
        }
      }
    }
    for (final id in ids) {
      if (!_isInk(layout, id)) continue;
      final unit = layout.unitOf(id);
      if (unit == null) continue;
      if (tool == SelectionTool.draw && !layout.isDrawing(unit)) continue;
      if (layout.touches(id, point, settings.inkHitRadius, settings: ink)) {
        return unit;
      }
    }
    return null;
  }

  /// A click or tap: [id] (or its group) becomes the only selected unit.
  ObjectSelection select(NoteDocument document, String id) {
    final unit = DocumentLayout.of(document)?.unitOf(id);
    return unit == null ? ObjectSelection.empty : ObjectSelection([unit]);
  }

  /// A click with the modifier (Shift) or a tap after touch and hold: adds the
  /// unit of [id] or removes it when it is already selected.
  ObjectSelection toggle(
    NoteDocument document,
    ObjectSelection selection,
    String id,
  ) {
    final unit = DocumentLayout.of(document)?.unitOf(id);
    if (unit == null) return selection;
    return selection.contains(unit)
        ? ObjectSelection(selection.ids.where((s) => s != unit))
        : ObjectSelection([...selection.ids, unit]);
  }

  /// A box drawn on empty paper from [a] to [b]: the units that lie
  /// completely inside it. In Draw mode only drawing units. With [addTo] the
  /// units are added to that selection (box with the modifier).
  ObjectSelection box(
    NoteDocument document,
    InkVec a,
    InkVec b, {
    SelectionTool tool = SelectionTool.type,
    ObjectSelection? addTo,
  }) {
    final layout = DocumentLayout.of(document);
    if (layout == null) return addTo ?? ObjectSelection.empty;
    final area = EditorRect.ofPoints([(a.x, a.y), (b.x, b.y)])!;
    bool inside(EditorRect r) =>
        r.left >= area.left &&
        r.top >= area.top &&
        r.right <= area.right &&
        r.bottom <= area.bottom;
    return ObjectSelection([
      ...?addTo?.ids,
      for (final unit in layout.units)
        if (tool == SelectionTool.type || layout.isDrawing(unit))
          if (layout.rectOf(unit) case final r? when inside(r)) unit,
    ]);
  }

  /// A lasso in Draw mode: the drawing units whose drawn line lies inside the
  /// closed [polygon] (see [SelectionSettings.lassoCoverage]). Text, cards
  /// and groups with a block are never selected by the lasso (B2.4).
  ObjectSelection lasso(
    NoteDocument document,
    List<InkVec> polygon, {
    ObjectSelection? addTo,
  }) {
    final layout = DocumentLayout.of(document);
    if (layout == null || polygon.length < 3) {
      return addTo ?? ObjectSelection.empty;
    }
    final out = <String>[...?addTo?.ids];
    for (final unit in layout.units) {
      if (!layout.isDrawing(unit)) continue;
      var total = 0, inside = 0;
      for (final id in layout.withDescendants(unit)) {
        for (final p in layout.linePoints(id, settings: ink) ?? const []) {
          total++;
          if (insidePolygon(p, polygon)) inside++;
        }
      }
      if (total > 0 && inside >= total * settings.lassoCoverage) out.add(unit);
    }
    return ObjectSelection(out);
  }

  /// Select all (Ctrl or Cmd with A): every unit, or every drawing unit in
  /// Draw mode.
  ObjectSelection all(
    NoteDocument document, {
    SelectionTool tool = SelectionTool.type,
  }) {
    final layout = DocumentLayout.of(document);
    if (layout == null) return ObjectSelection.empty;
    return ObjectSelection([
      for (final unit in layout.units)
        if (tool == SelectionTool.type || layout.isDrawing(unit)) unit,
    ]);
  }

  /// The selection that still exists in [document] after an edit, Undo or
  /// Redo: units that were removed or became members of a group drop out.
  ObjectSelection prune(NoteDocument document, ObjectSelection selection) {
    final layout = DocumentLayout.of(document);
    if (layout == null) return ObjectSelection.empty;
    return ObjectSelection(
      selection.ids.where((id) => layout.unitOf(id) == id),
    );
  }

  /// The outside rectangle of the selection, for its frame and for paste.
  EditorRect? bounds(NoteDocument document, ObjectSelection selection) =>
      DocumentLayout.of(document)?.boundsOf(selection.ids);
}

bool _isInk(DocumentLayout layout, String id) =>
    const ['stroke', 'shape'].contains(layout.kindOf(id));

bool _isLeafBlock(DocumentLayout layout, String id) =>
    !_isInk(layout, id) && !layout.isGroup(id);
