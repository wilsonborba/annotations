/// Where a click in Type mode starts or opens a text block (annotations#27).
///
/// The free space comes from the editor rules: a new block is a candidate
/// `add` of an empty text item, checked by [EditorRules.check]. Nothing here
/// keeps its own copy of the collision rule; a rejection only tells which
/// blocks are in the way, and the width ends before them.
library;

import 'dart:math' as math;

import '../../core/note_limits.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'object_selection.dart';
import 'text_editing.dart';

final class TextBlocks {
  const TextBlocks({this.selector = const ObjectSelector()});

  final ObjectSelector selector;

  /// The top text item at [point] (page units), or null. Text under ink
  /// stays reachable in Type mode (B2.4).
  String? textAt(DocumentLayout layout, InkVec point) {
    for (final id in layout.ids.reversed) {
      if (layout.kindOf(id) == 'text' && layout.touches(id, point, 0)) {
        return id;
      }
    }
    return null;
  }

  /// True when nothing is at [point] in Type mode: no block and no ink. A
  /// click on ink is kept for selecting it (annotations#32); a new block may
  /// still overlap ink, because free ink reserves no space (B2.4).
  bool isEmptyPaper(DocumentLayout layout, InkVec point) =>
      selector.hitIn(layout, point, SelectionTool.type) == null;

  /// The place of a new text block [id] with its top left corner in the grid
  /// cell that holds [x], [y] (B2.1).
  ///
  /// The block is [width] wide at most, in whole cells, and ends at the page
  /// edge. When the
  /// editor rules reject the empty block because blocks to the right are in
  /// the way, the width ends where the nearest of them starts. Returns null
  /// when no block of at least [minWidth] fits there. [lineHeight] is the
  /// measured height of an empty block at a width.
  TextBlockPlace? place(
    EditorRules rules,
    NoteDocument document, {
    required String id,
    required num x,
    required num y,
    required num width,
    required num minWidth,
    required num Function(num width) lineHeight,
  }) {
    if (document is! PaperDocument) return null;
    final left = EditorGrid.floor(x), top = EditorGrid.floor(y);
    num w = EditorGrid.floor(math.min(width, document.page.width - left));
    final layout = DocumentLayout.of(document);
    while (w >= minWidth) {
      final decision = rules.check(document, {
        'op': 'add',
        'item': {
          'id': id,
          'kind': 'text',
          'x': left,
          'y': top,
          'width': w,
          'height': lineHeight(w),
          'spans': const <Object?>[],
        },
      });
      if (decision.accepted) return TextBlockPlace(left, top, w);
      final error = decision.error!;
      if (error.code != EditorRule.blockOverlap &&
          error.code != EditorRule.groupOverlap) {
        return null;
      }
      num? end;
      for (final other in error.items) {
        if (other == id) continue;
        final rect = layout?.rectOf(other);
        if (rect == null || rect.left <= left) return null;
        end = math.min(end ?? rect.left, rect.left);
      }
      if (end == null) return null;
      final next = EditorGrid.floor(end - left);
      if (next >= w) return null;
      w = next;
    }
    return null;
  }
}
