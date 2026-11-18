/// Actions on selected objects and the clipboard (B2 G1, confirmed by the
/// owner): copy, cut, paste, duplicate, delete, group and ungroup. Mouse,
/// keyboard, touch and pen call the same functions; this file has no gesture
/// or menu code.
///
/// Every change is one candidate of [EditorRules] and goes through the editor
/// session: one step of the one Notes history, or an Instant edit without
/// history. A candidate that does not fit adds nothing (B2.3), the clipboard
/// stays as it was, and a rejected cut keeps its source.
///
/// Internal copy keeps whole objects: the relative layout, editable ink and
/// group members. Paste and duplicate give every copy a new id. Copy to other
/// apps gives plain text for text and a picture for a picture. Paste from
/// other apps maps sanitized text (see rich_paste.dart) or a picture to
/// supported items; no script runs and nothing remote is fetched.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/note_limits.dart';
import '../../core/selection_settings.dart';
import '../../dal/local/picture_composer.dart';
import '../../dal/local/system_clipboard.dart';
import '../../dal/local/text_engine.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'note_history.dart';
import 'object_selection.dart';
import 'rich_paste.dart';

/// Item fields that reference a stored file.
const _fileFields = ['file_id', 'preview_file_id'];

/// The result of an object action: the decision of the editor rules and the
/// selection after it. [decision] is null when the action had nothing to do
/// or stopped before the rules (see [error]). After a rejection [selection] is
/// the selection before the action.
final class ObjectEdit {
  const ObjectEdit._(this.decision, this.selection, [this._error]);

  final EditDecision? decision;
  final ObjectSelection selection;
  final EditorRuleError? _error;

  bool get accepted => decision?.accepted ?? false;

  /// Why the action changed nothing: a rule error, or `file_access` (rule
  /// [EditorRule.editor]) when a pasted item references a file that the user
  /// cannot use. Null when the action was accepted or had nothing to do.
  EditorRuleError? get error => decision?.error ?? _error;
}

/// Files of the open document, for paste and for copy to other apps. The
/// local store (annotations#25) and the remote adapters implement it; the
/// server and the store own access, as for every other file action.
abstract interface class ClipboardFiles {
  /// Whether the user can use the stored file [fileId] in [document]. An
  /// internal paste checks every referenced file before it adds anything.
  Future<bool> canUse(NoteDocument document, String fileId);

  /// The encoded picture of [fileId] for copy to other apps, or null.
  Future<Uint8List?> pictureBytes(String fileId);

  /// Keeps a picture from another app as a new file of [document], or null
  /// when the bytes are not a supported picture. It never fetches anything.
  Future<StoredPicture?> storePicture(NoteDocument document, Uint8List bytes);

  /// Removes a picture kept by [storePicture] whose paste was rejected.
  Future<void> discardPicture(String fileId);
}

/// A picture file and its natural size in logical page units.
final class StoredPicture {
  const StoredPicture(this.fileId, this.width, this.height);
  final String fileId;
  final num width, height;
}

/// Copies of whole objects, ready to paste. The items keep their source ids
/// (paste gives new ids) and are in document order; [units] are the
/// top-level objects among them.
final class ClipboardContent {
  ClipboardContent._(List<JsonObject> items, this.units, this.bounds)
    : _items = List.unmodifiable(items);

  final List<JsonObject> _items;
  final List<String> units;

  /// The outside rectangle of all copied objects in the source.
  final EditorRect bounds;

  /// JSON copies of the items.
  List<JsonObject> get items => [for (final it in _items) _copyJson(it)];

  /// The stored files that the items reference.
  Set<String> get fileIds => {
    for (final it in _items)
      for (final f in _fileFields)
        if (it[f] case final String id) id,
  };

  /// The text of the text items in reading order (top to bottom, then left
  /// to right), one empty line between items: the plain text for other apps.
  String get plainText {
    final texts = _items.where((it) => it['kind'] == 'text').toList()
      ..sort((a, b) {
        final byTop = (a['y'] as num).compareTo(b['y'] as num);
        return byTop != 0 ? byTop : (a['x'] as num).compareTo(b['x'] as num);
      });
    return [
      for (final it in texts)
        [for (final s in it['spans'] as List) (s as Map)['text']].join(),
    ].join('\n\n');
  }

  /// The pictures in document order (drawing order) with their rectangles,
  /// for copy to other apps.
  List<(String, EditorRect)> get pictures => [
    for (final it in _items)
      if (it['kind'] == 'image')
        (
          it['file_id'] as String,
          EditorRect(
            it['x'] as num,
            it['y'] as num,
            (it['x'] as num) + (it['width'] as num),
            (it['y'] as num) + (it['height'] as num),
          ),
        ),
  ];
}

/// Selection actions that need no clipboard.
final class ObjectActions {
  const ObjectActions({
    required this.newId,
    this.settings = const SelectionSettings(),
  });

  /// A new unique item id for each copy and each new group.
  final String Function() newId;
  final SelectionSettings settings;

  /// Deletes the selected objects; a group goes with all its members.
  ObjectEdit delete(EditorSession session, ObjectSelection selection) {
    if (selection.isEmpty) return ObjectEdit._(null, selection);
    final decision = _apply(
      session,
      CommandKind.remove,
      (rules, document) => rules.remove(document, selection.ids),
    );
    return ObjectEdit._(
      decision,
      decision.accepted ? ObjectSelection.empty : selection,
    );
  }

  /// Copies the selection to the first free grid position below itself at
  /// the same x (annotations#24): the copy starts at the first whole cell
  /// under the selection and moves down past each block in its way. The page
  /// grows downward, so a place is always found; nothing else moves.
  ObjectEdit duplicate(EditorSession session, ObjectSelection selection) {
    final layout = DocumentLayout.of(session.document);
    final bounds = layout?.boundsOf(selection.ids);
    if (layout == null || bounds == null) return ObjectEdit._(null, selection);
    final copied = _withMembers(layout, selection.ids);
    final dy = _freeBelow(session, selection, bounds);
    final assigned = <String>[];
    final decision = _apply(
      session,
      CommandKind.duplicate,
      (rules, document) => rules.duplicate(
        document,
        selection.ids,
        dy: dy,
        newId: () => _record(assigned, newId()),
      ),
    );
    if (!decision.accepted) return ObjectEdit._(decision, selection);
    final units = selection.inDocumentOrder(layout);
    return ObjectEdit._(
      decision,
      ObjectSelection([for (final u in units) assigned[copied.indexOf(u)]]),
    );
  }

  /// Groups the selected objects (at least two) into one new group.
  ObjectEdit group(EditorSession session, ObjectSelection selection) {
    if (selection.ids.length < 2) return ObjectEdit._(null, selection);
    final id = newId();
    final decision = _apply(
      session,
      CommandKind.group,
      (rules, document) => rules.group(document, selection.ids, id),
    );
    return ObjectEdit._(
      decision,
      decision.accepted ? ObjectSelection([id]) : selection,
    );
  }

  /// Ungroups the selected groups. Their members stay in place and become
  /// selected; other selected objects stay selected.
  ObjectEdit ungroup(EditorSession session, ObjectSelection selection) {
    final layout = DocumentLayout.of(session.document);
    if (layout == null) return ObjectEdit._(null, selection);
    final groups = selection.ids.where(layout.isGroup).toList();
    if (groups.isEmpty) return ObjectEdit._(null, selection);
    final decision = _apply(
      session,
      CommandKind.ungroup,
      (rules, document) => rules.ungroup(document, groups),
    );
    if (!decision.accepted) return ObjectEdit._(decision, selection);
    return ObjectEdit._(
      decision,
      ObjectSelection([
        for (final id in selection.ids)
          ...groups.contains(id) ? layout.membersOf(id) : [id],
      ]),
    );
  }
}

/// The clipboard of the app: the internal copy of whole objects, and the
/// system clipboard for other apps.
final class ObjectClipboard {
  ObjectClipboard({
    required this.system,
    required this.files,
    required this.engine,
    required this.newId,
    this.settings = const SelectionSettings(),
    this.composer = const UiPictureComposer(),
  });

  final SystemClipboard system;
  final ClipboardFiles files;

  /// Renders several selected pictures as laid out into one picture.
  final PictureComposer composer;

  /// Measures the height of pasted text, like every text edit (type C).
  final TextEngine engine;
  final String Function() newId;
  final SelectionSettings settings;

  ClipboardContent? _content;

  /// What this app wrote to the system clipboard with [_content]: a later
  /// copy in another app changes it, and then paste uses the other app.
  String? _writtenText;
  Uint8List? _writtenPicture;

  /// The internal copy, or null.
  ClipboardContent? get content => _content;

  /// Copies the selected objects. Returns the copy, or null for an empty
  /// selection. Copy never changes the document.
  Future<ClipboardContent?> copy(
    EditorSession session,
    ObjectSelection selection,
  ) async {
    final content = _contentOf(session.document, selection);
    if (content == null) return null;
    await _write(content);
    return content;
  }

  /// Copies the selected objects and deletes them as one step. When the
  /// deletion is rejected the source stays and the clipboard does not change.
  Future<ObjectEdit> cut(
    EditorSession session,
    ObjectSelection selection,
  ) async {
    final content = _contentOf(session.document, selection);
    if (content == null) return ObjectEdit._(null, selection);
    final probe = session.rules.remove(session.document, selection.ids);
    if (!probe.accepted) return ObjectEdit._(probe, selection);
    await _write(content);
    return ObjectActions(
      newId: newId,
      settings: settings,
    ).delete(session, selection);
  }

  /// Pastes with the top left corner of the pasted objects at [at] (kept
  /// inside the page width). The internal copy is pasted when the system
  /// clipboard still holds what this app wrote; otherwise the content of the
  /// other app is pasted: sanitized text as a text block, or a picture. A
  /// paste that does not fit adds nothing and keeps the clipboard.
  Future<ObjectEdit> paste(
    EditorSession session,
    InkVec at,
    ObjectSelection selection,
  ) async {
    final content = _content;
    if (content != null && await _ownsSystemClipboard()) {
      return _pasteInternal(session, content, at, selection);
    }
    return _pasteExternal(session, at, selection);
  }

  /// Sanitized text of another app for the text block that has the focus
  /// ([TextFocus]): the text engine inserts it with [insertSpans] as one
  /// replacing change. Null when the clipboard has no text.
  Future<TextSpans?> readExternalText() async {
    final html = await _guard(system.readHtml);
    if (html != null) {
      final spans = sanitizeHtml(html);
      if (spans.isNotEmpty) return spans;
    }
    final text = await _guard(system.readText);
    if (text == null || text.isEmpty) return null;
    final spans = sanitizePlainText(text);
    return spans.isEmpty ? null : spans;
  }

  // Internal ------------------------------------------------------------------

  ClipboardContent? _contentOf(
    NoteDocument document,
    ObjectSelection selection,
  ) {
    final layout = DocumentLayout.of(document);
    final bounds = layout?.boundsOf(selection.ids);
    if (layout == null || bounds == null) return null;
    return ClipboardContent._(
      [
        for (final id in _withMembers(layout, selection.ids))
          layout.itemJson(id)!,
      ],
      selection.inDocumentOrder(layout),
      bounds,
    );
  }

  /// Copy to other apps (B2 G1): text goes as plain text, pictures go as
  /// pictures. A selection with both gives one clipboard item with the text
  /// and the selected pictures rendered as laid out.
  Future<void> _write(ClipboardContent content) async {
    _content = content;
    final text = content.plainText;
    _writtenText = text;
    _writtenPicture = null;
    final picture = await _picture(content);
    if (picture != null) {
      if (text.isEmpty) {
        if (await _guard(() => system.writeImage(picture)) == true) {
          _writtenText = null;
          _writtenPicture = picture;
          return;
        }
      } else if (await _guard(() => system.writeTextAndImage(text, picture)) ==
          true) {
        return;
      }
    }
    // An empty text also replaces what another app copied before.
    await _guard(() => system.writeText(text));
  }

  /// One picture for the selected pictures: the stored bytes of a single
  /// picture, or the pictures rendered as laid out. Null without pictures.
  Future<Uint8List?> _picture(ClipboardContent content) async {
    final placed = <PlacedPicture>[];
    for (final (fileId, r) in content.pictures) {
      final bytes = await _guard(() => files.pictureBytes(fileId));
      if (bytes == null) continue;
      placed.add((
        bytes: bytes,
        left: r.left.toDouble(),
        top: r.top.toDouble(),
        width: r.width.toDouble(),
        height: r.height.toDouble(),
      ));
    }
    if (placed.isEmpty) return null;
    if (placed.length == 1) return placed.single.bytes;
    return _guard<Uint8List?>(() => composer.compose(placed));
  }

  Future<bool> _ownsSystemClipboard() async {
    final text = await _guard(system.readText) ?? '';
    final written = _writtenPicture;
    if (written != null) {
      if (text.isNotEmpty) return false;
      final image = await _guard(system.readImage);
      return image != null && listEquals(image, written);
    }
    if (text != (_writtenText ?? '')) return false;
    // Nothing of this app is readable as text: a picture of another app wins.
    return text.isNotEmpty || await _guard(system.readImage) == null;
  }

  Future<ObjectEdit> _pasteInternal(
    EditorSession session,
    ClipboardContent content,
    InkVec at,
    ObjectSelection selection,
  ) async {
    final document = session.document;
    final denied = <String>[];
    for (final it in content._items) {
      for (final f in _fileFields) {
        if (it[f] case final String fileId) {
          if (await _guard(() => files.canUse(document, fileId)) != true) {
            denied.add(it['id'] as String);
          }
        }
      }
    }
    if (denied.isNotEmpty) {
      return ObjectEdit._(
        null,
        selection,
        EditorRuleError(EditorRule.editor, 'file_access', 'items', denied),
      );
    }
    if (session.document is! PaperDocument) {
      return ObjectEdit._(null, selection);
    }
    final page = (session.document as PaperDocument).page.width;
    final target = _place(at, content.bounds.width, page);
    final ids = [for (final it in content._items) it['id'] as String];
    final assigned = <String>[];
    final decision = _apply(
      session,
      CommandKind.paste,
      (rules, document) => rules.paste(
        document,
        content.items,
        dx: target.x - content.bounds.left,
        dy: target.y - content.bounds.top,
        newId: () => _record(assigned, newId()),
      ),
    );
    if (!decision.accepted) return ObjectEdit._(decision, selection);
    return ObjectEdit._(
      decision,
      ObjectSelection([
        for (final u in content.units) assigned[ids.indexOf(u)],
      ]),
    );
  }

  Future<ObjectEdit> _pasteExternal(
    EditorSession session,
    InkVec at,
    ObjectSelection selection,
  ) async {
    final document = session.document;
    if (document is! PaperDocument) return ObjectEdit._(null, selection);
    final page = document.page.width;
    final spans = await readExternalText();
    if (spans != null) {
      final width = EditorGrid.floor(
        page < settings.externalTextWidth ? page : settings.externalTextWidth,
      );
      final target = _place(at, width, page);
      final room = EditorGrid.floor(page - target.x);
      final w = room < width ? room : width;
      final num height;
      try {
        height = engine.measureHeight(spans, w);
      } on TextContentException catch (e) {
        return ObjectEdit._(
          null,
          selection,
          EditorRuleError(EditorRule.editor, e.code, 'spans'),
        );
      }
      return _pasteItem(session, selection, {
        'id': 'text',
        'kind': 'text',
        'x': target.x,
        'y': target.y,
        'width': w,
        'height': height,
        'spans': spans,
      });
    }
    final bytes = await _guard(system.readImage);
    if (bytes == null) return ObjectEdit._(null, selection);
    final picture = await _guard(() => files.storePicture(document, bytes));
    if (picture == null) return ObjectEdit._(null, selection);
    final cells = math.max(EditorGrid.cell, EditorGrid.floor(picture.width));
    final target = _place(at, cells, page);
    final room = EditorGrid.floor(page - target.x);
    final width = cells < room ? cells : room;
    final edit = _pasteItem(session, selection, {
      'id': 'image',
      'kind': 'image',
      'x': target.x,
      'y': target.y,
      'width': width,
      'height': picture.height * width / picture.width,
      'file_id': picture.fileId,
    });
    if (!edit.accepted) {
      await _guard(() => files.discardPicture(picture.fileId));
    }
    return edit;
  }

  ObjectEdit _pasteItem(
    EditorSession session,
    ObjectSelection selection,
    JsonObject item,
  ) {
    final assigned = <String>[];
    final decision = _apply(
      session,
      CommandKind.paste,
      (rules, document) => rules.paste(document, [
        item,
      ], newId: () => _record(assigned, newId())),
    );
    return ObjectEdit._(
      decision,
      decision.accepted ? ObjectSelection(assigned) : selection,
    );
  }
}

/// The spans of [content] with [length] characters at [offset] replaced by
/// [inserted], each inserted span with its own bold, italic, strikethrough
/// and color. The size follows the text around it. The text engine commits
/// the result as one replacing change through its binding (type C guard).
TextSpans insertSpans(
  TextContent content,
  int offset,
  int length,
  TextSpans inserted,
) {
  final text = [for (final s in inserted) s['text'] as String].join();
  var out = content.replaced(offset, length, text);
  var at = offset;
  for (final span in inserted) {
    final n = (span['text'] as String).length;
    if (n == 0) continue;
    for (final format in [
      TextFormat.bold(span['bold'] == true),
      TextFormat.italic(span['italic'] == true),
      TextFormat.strikethrough(span['strikethrough'] == true),
      TextFormat.color(span['color'] as String?),
    ]) {
      out = out.formatted(at, n, format);
    }
    at += n;
  }
  return out.toSpans();
}

// Helpers ---------------------------------------------------------------------

EditDecision _apply(
  EditorSession session,
  CommandKind kind,
  EditBuilder build,
) => switch (session) {
  final NotesEditor notes => notes.apply(HistoryCommand(kind), build),
  final InstantEditor instant => instant.apply(build),
};

/// The first downward shift in whole cells at which a copy of [selection]
/// fits. A rejected try names the block in the way; the next try starts
/// the blocked copy below that block's cells.
num _freeBelow(
  EditorSession session,
  ObjectSelection selection,
  EditorRect bounds,
) {
  final document = session.document;
  final rules = session.rules;
  final first = math.max(EditorGrid.cell, EditorGrid.ceil(bounds.height));
  final all = DocumentLayout.of(document);
  final end = all?.boundsOf(all.ids);
  final limit = (end?.bottom ?? bounds.bottom) - bounds.top + EditorGrid.cell;
  num dy = first;
  var probe = 0;
  while (dy <= limit) {
    final d = rules.duplicate(
      document,
      selection.ids,
      dy: dy,
      newId: () => '__duplicate_probe_${probe++}',
    );
    if (d.accepted) return dy;
    final error = d.error!;
    final candidate = d.candidate;
    if (candidate == null ||
        (error.code != EditorRule.blockOverlap &&
            error.code != EditorRule.groupOverlap)) {
      return first;
    }
    final after = DocumentLayout.of(
      NoteDocument.fromJson(candidate, schema: document.schema),
    );
    final copy = error.items.firstWhere(
      (id) => id.startsWith('__duplicate_probe_'),
      orElse: () => '',
    );
    final blocker = error.items.firstWhere((id) => id != copy);
    final copyRect = after?.rectOf(copy)?.cells;
    final blockRect = after?.rectOf(blocker)?.cells;
    if (copyRect == null || blockRect == null) return first;
    dy += math.max(EditorGrid.cell, blockRect.bottom - copyRect.top);
  }
  return dy;
}

/// The selected objects with all their group members, in document order,
/// the order in which the rules copy them.
List<String> _withMembers(DocumentLayout layout, List<String> ids) {
  final all = {for (final id in ids) ...layout.withDescendants(id)};
  return [
    for (final id in layout.ids)
      if (all.contains(id)) id,
  ];
}

String _record(List<String> assigned, String id) {
  assigned.add(id);
  return id;
}

/// The top left corner for an object of [width] at [at], inside the page: the
/// grid cell that holds [at] (B2.1), moved left when the object would pass the
/// page edge.
InkVec _place(InkVec at, num width, num page) {
  final maxX = EditorGrid.floor(page - width);
  final x = math.min(EditorGrid.floor(at.x), maxX);
  final y = EditorGrid.floor(at.y);
  return InkVec(x < 0 ? 0 : x.toDouble(), y < 0 ? 0 : y.toDouble());
}

JsonObject _copyJson(JsonObject value) =>
    jsonDecode(jsonEncode(value)) as JsonObject;

/// Clipboard calls fail on some platforms (permissions, unsupported data);
/// a failure reads as nothing.
Future<T?> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on Object {
    return null;
  }
}
