/// Editor placement rules that work offline, the same as the backend checks.
///
/// Every edit is a candidate: it is applied to a working copy, the copy is
/// checked, and only an accepted result is returned for commit. Nothing here
/// mutates a stored document, moves a neighbor or keeps history. Text is never
/// measured here: the app measures it with its text engine and passes the size.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../core/ink_settings.dart';
import '../../core/note_limits.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import '../models/reports_card_reference.dart';
import '../models/stroke_samples_codec.dart';
import 'ink_geometry.dart';
import 'ink_outline.dart';

part 'editor_actions.dart';
part 'editor_geometry.dart';
part 'editor_incremental.dart';
part 'editor_validation.dart';
part 'ink_edits.dart';
part 'ink_erase.dart';

typedef JsonObject = Map<String, Object?>;

/// Rule ids shared with the backend fixtures, plus [editor]
/// for app-side preconditions of a gesture.
abstract final class EditorRule {
  static const grid = 'grid';
  static const blockOverlap = 'block_overlap';
  static const groupOverlap = 'group_overlap';
  static const freeInkOverlap = 'free_ink_overlap';
  static const pageBounds = 'page_bounds';
  static const operation = 'operation';
  static const documentSchema = 'document_schema';

  /// App-side preconditions of a gesture, which the server never sees:
  /// `measurement_required`, `below_minimum_size` and `not_resizable`.
  static const editor = 'editor';
}

/// A rejected edit: the broken [rule], the stable [code] (the reason), the
/// [path] of the failing value and the conflicting item ids in document order.
/// It never contains note content.
final class EditorRuleError implements Exception {
  EditorRuleError(
    this.rule,
    this.code,
    this.path, [
    Iterable<String> items = const [],
  ]) : items = List.unmodifiable(items);

  final String rule, code, path;
  final List<String> items;

  @override
  String toString() => '$code (rule $rule) at $path';
}

/// The result of a candidate edit.
///
/// When accepted, [document] is the new document to commit. When rejected,
/// [document] is the unchanged original, and [operation] still holds the
/// requested change (composing text, pasted items), so no input is lost.
final class EditDecision {
  EditDecision._(
    this.document,
    this.error,
    Object? candidate,
    Object? operation,
  ) : _candidate = candidate,
      _candidateOf = null,
      _operation = _jsonCopy(operation);

  /// An accepted decision from the changed items only (annotations#62): the
  /// working copy is the new document, built only when asked for.
  EditDecision._lazy(this.document, Object? operation)
    : error = null,
      _candidate = null,
      _candidateOf = document.toJson,
      _operation = _jsonCopy(operation);

  final NoteDocument document;
  final EditorRuleError? error;
  // The working copy is owned by the decision: the rules never keep it.
  final Object? _candidate;
  final JsonObject Function()? _candidateOf;
  final Object? _operation;

  bool get accepted => error == null;

  /// The working copy after the operation, for the proposed position or size
  /// while dragging. Null when the operation could not be applied at all.
  JsonObject? get candidate =>
      _candidateOf?.call() ?? _jsonCopy(_candidate) as JsonObject?;

  /// The requested operation, kept for the UI after a rejection.
  Object? get operation => _jsonCopy(_operation);
}

/// The corner that stays in place during a resize.
enum ResizeAnchor { topLeft, topRight, bottomLeft, bottomRight }

/// The effective font size of a text span that has no stored `size`, as the app
/// renders it. Asked only when a whole-group scale has to store a scaled size.
typedef FontSizeResolver = num? Function(String itemId, int spanIndex);

final class EditorRules {
  const EditorRules({
    this.limits = const NoteLimits(),
    this.settings = const EditorSettings(),
  });
  final NoteLimits limits;
  final EditorSettings settings;

  /// Applies [operation] (if any) to a working copy of [document], then checks
  /// the document schema and the placement rules. The operation format is the
  /// one of the shared rule fixtures: `add`, `replace`, `update`, `delete`,
  /// `page` and `batch`.
  EditDecision check(NoteDocument document, [Object? operation]) {
    final schema = document.schema;
    final Object? op;
    try {
      op = _jsonCopy(operation);
    } on JsonUnsupportedObjectError {
      return _reject(document, _opError('invalid_operation', 'operation'));
    }
    if (document is PaperDocument) {
      if (op == null && _known(document, limits) != null) {
        return EditDecision._lazy(document, null);
      }
      if (_incremental(document, op, limits) case final fast?) return fast;
    }
    JsonObject? candidate;
    try {
      final copy = document.toJson();
      if (op != null) _apply(schema, copy, op);
      candidate = copy;
      final _Ctx ctx;
      try {
        ctx = _checkDocument(schema, candidate, limits);
      } on DocumentFormatException catch (e) {
        throw _schemaError(e, candidate);
      }
      _Layout? layout;
      if (schema.family != DocumentFamily.typed) {
        layout = _Layout(candidate['items'] as List<Object?>)..check();
      }
      final NoteDocument next;
      try {
        next = NoteDocument.fromJson(candidate, schema: schema);
      } on DocumentFormatException catch (e) {
        throw _schemaError(e, candidate);
      }
      if (next is PaperDocument && layout != null) {
        _remember(next, limits, ctx, layout);
      }
      return EditDecision._(next, null, candidate, op);
    } on EditorRuleError catch (e) {
      return EditDecision._(document, e, candidate, op);
    }
  }

  /// The page offset that [move] applies for [dx], [dy]: rounded to 1/100,
  /// and on whole grid cells when a block moves. The proposed position
  /// while dragging (annotations#32).
  (num, num) moveDelta(
    NoteDocument document,
    List<String> ids,
    num dx,
    num dy,
  ) {
    if (document is! PaperDocument) return (dx, dy);
    final layout = _Layout(document.itemsJson);
    try {
      final moved = _indexes(layout, ids, withDescendants: true);
      return _delta([for (final i in moved) layout.items[i]], dx, dy);
    } on EditorRuleError {
      return (dx, dy);
    }
  }

  /// Checks [document] with its items replaced by [items], in that order.
  /// Unchanged items are the same objects as [PaperDocument.itemsJson]; the
  /// others are new JSON. On a checked document only the changed items are
  /// checked (annotations#62), so Undo and Redo stay fast on a long note.
  EditDecision checkItems(PaperDocument document, List<Object?> items) {
    if (_incrementalList(document, items, limits) case final fast?) {
      return fast;
    }
    final json = {...document.toJsonWithoutItems(), 'items': _jsonCopy(items)};
    final NoteDocument candidate;
    try {
      candidate = NoteDocument.fromJson(json, schema: document.schema);
    } on DocumentFormatException catch (e) {
      return _reject(document, _schemaError(e, json));
    }
    final decision = check(candidate);
    return decision.accepted
        ? decision
        : EditDecision._(document, decision.error, json, null);
  }

  /// Moves the items [ids] by [dx], [dy] page units (rounded to 1/100). A group
  /// moves with all its members. Call it during a drag for the proposed
  /// position; commit only an accepted decision on drop.
  EditDecision move(NoteDocument document, List<String> ids, num dx, num dy) =>
      _run(document, (layout) => _moveOperation(layout, ids, dx, dy));

  /// Resizes one item with its own B3 rule, or scales a whole group from a
  /// corner. [width] is the new outside width. [height] is used only by kinds
  /// with a free area (CSV table, Reports embed). Text and cards whose text
  /// wraps need [measuredHeight], measured by the app at the new width; whole
  /// group scales need [measuredHeights] for their cards. A missing
  /// measurement is a rejection with code `measurement_required`.
  EditDecision resize(
    NoteDocument document,
    String id, {
    required num width,
    num? height,
    ResizeAnchor anchor = ResizeAnchor.topLeft,
    num? measuredHeight,
    Map<String, num> measuredHeights = const {},
    FontSizeResolver? effectiveFontSize,
  }) => _run(
    document,
    (layout) => _resizeOperation(
      layout,
      settings,
      id,
      width: width,
      height: height,
      anchor: anchor,
      measuredHeight: measuredHeight,
      measuredHeights: measuredHeights,
      effectiveFontSize: effectiveFontSize,
    ),
  );

  /// Type C text input: new [spans] at the same width with the height that the
  /// app measured. Text grows only into free space; an overlap is rejected and
  /// the decision keeps the spans.
  EditDecision editText(
    NoteDocument document,
    String id, {
    required List<Object?> spans,
    required num? measuredHeight,
  }) => _run(
    document,
    (layout) => _textOperation(layout, id, spans, measuredHeight),
  );

  /// Adds copies of [items] (an internal clipboard) with new ids from [newId],
  /// moved by [dx], [dy]. Groups keep their members through the new ids. If
  /// the copies do not fit, nothing is added and the decision keeps them.
  EditDecision paste(
    NoteDocument document,
    List<Object?> items, {
    num dx = 0,
    num dy = 0,
    required String Function() newId,
  }) => _run(
    document,
    (layout) => _pasteOperation(document.schema, items, dx, dy, newId),
  );

  /// Duplicates the items [ids] (groups with all their members), like a paste.
  EditDecision duplicate(
    NoteDocument document,
    List<String> ids, {
    num dx = 0,
    num dy = 0,
    required String Function() newId,
  }) => _run(document, (layout) {
    final copies = [
      for (final i in _indexes(layout, ids, withDescendants: true))
        layout.items[i],
    ];
    return _pasteOperation(document.schema, copies, dx, dy, newId);
  });

  /// Deletes the items [ids]; a group goes with all its members (B2.6). Pass
  /// whole objects: a member alone would leave its group incomplete, which
  /// the schema check rejects.
  EditDecision remove(NoteDocument document, List<String> ids) =>
      _run(document, (layout) => _removeOperation(layout, ids));

  /// Groups the items [ids] (at least two, none already in a group) under the
  /// new group [id]. Members keep their positions; the outside rectangle of
  /// the group must not overlap another block (B2.5).
  EditDecision group(NoteDocument document, List<String> ids, String id) =>
      _run(document, (layout) => _groupOperation(layout, ids, id));

  /// Removes the groups [ids]. Each member keeps its current page position
  /// and becomes an independent object again (B2.5).
  EditDecision ungroup(NoteDocument document, List<String> ids) =>
      _run(document, (layout) => _ungroupOperation(layout, ids));

  /// Builds an operation from the layout of a valid paper document and checks
  /// it. A builder failure is a rejection that keeps its operation if any.
  /// A builder that returns null changes nothing: the decision is accepted
  /// with the unchanged document.
  EditDecision _run(
    NoteDocument document,
    JsonObject? Function(_Layout layout) build,
  ) {
    if (document is! PaperDocument) {
      return _reject(document, _opError('invalid_operation', 'operation'));
    }
    final List<Object?> items;
    if (_known(document, limits) != null) {
      // Checked before (annotations#62): the builders read the stored items.
      items = document.itemsJson;
    } else {
      final current = document.toJson();
      try {
        _checkDocument(document.schema, current, limits);
      } on DocumentFormatException catch (e) {
        return _reject(document, _schemaError(e, current));
      }
      items = current['items'] as List<Object?>;
    }
    final JsonObject? operation;
    try {
      operation = build(_Layout(items));
    } on _Rejected catch (r) {
      return EditDecision._(document, r.error, null, r.operation);
    } on EditorRuleError catch (e) {
      return _reject(document, e);
    }
    if (operation == null) {
      return EditDecision._(document, null, document.toJson(), null);
    }
    return check(document, operation);
  }

  // Operations ---------------------------------------------------------------

  void _apply(DocumentSchema schema, JsonObject copy, Object operation) {
    if (schema.family == DocumentFamily.typed) {
      throw _opError('invalid_operation', 'operation');
    }
    if (copy['items'] is! List) {
      throw EditorRuleError(
        EditorRule.documentSchema,
        'missing_field',
        'items',
      );
    }
    final op = _object(operation, 'operation');
    if (_kind(op, 'operation') == 'batch') {
      _allow(op, ['op', 'steps'], 'operation');
      final steps = op['steps'];
      if (steps is! List || steps.isEmpty || steps.length > limits.maxItems) {
        throw _opError('invalid_operation', 'operation.steps');
      }
      for (var i = 0; i < steps.length; i++) {
        final path = 'operation.steps[$i]';
        _documentStep(copy, _object(steps[i], path), path);
      }
    } else {
      _documentStep(copy, op, 'operation');
    }
  }

  void _documentStep(JsonObject copy, JsonObject step, String path) {
    if (_kind(step, path) == 'page') {
      _allow(step, ['op', 'page'], path);
      copy['page'] = _object(step['page'], '$path.page');
      return;
    }
    final items = copy['items'];
    if (items is! List<Object?>) {
      throw EditorRuleError(
        EditorRule.documentSchema,
        'missing_field',
        'items',
      );
    }
    switch (_kind(step, path)) {
      case 'add':
        _allow(step, ['op', 'item'], path);
        items.add(_object(step['item'], '$path.item'));
      case 'replace':
        _allow(step, ['op', 'item'], path);
        final item = _object(step['item'], '$path.item');
        final id = item['id'];
        if (id is! String) throw _opError('invalid_operation', '$path.item.id');
        final i = _find(items, id, '$path.item.id');
        if (jsonEncode((items[i] as Map)['kind']) != jsonEncode(item['kind'])) {
          throw _opError('immutable_field', '$path.item.kind', [id]);
        }
        items[i] = item;
      case 'update':
        _allow(step, ['op', 'id', 'changes'], path);
        final id = step['id'];
        if (id is! String) throw _opError('invalid_operation', '$path.id');
        final changes = _object(step['changes'], '$path.changes');
        final i = _find(items, id, '$path.id');
        final keys = changes.keys.toList()..sort();
        for (final k in keys) {
          if (k == 'id' || k == 'kind') {
            throw _opError('immutable_field', '$path.changes.$k', [id]);
          }
        }
        final item = items[i];
        if (item is! JsonObject) {
          throw EditorRuleError(
            EditorRule.documentSchema,
            'invalid_type',
            'items[$i]',
          );
        }
        for (final MapEntry(:key, :value) in changes.entries) {
          value == null ? item.remove(key) : item[key] = value;
        }
      case 'delete':
        _allow(step, ['op', 'id'], path);
        final id = step['id'];
        if (id is! String) throw _opError('invalid_operation', '$path.id');
        items.removeAt(_find(items, id, '$path.id'));
      default:
        // A batch inside a batch is not allowed.
        throw _opError('invalid_operation', '$path.op');
    }
  }
}

EditorRuleError _opError(
  String code,
  String path, [
  List<String> ids = const [],
]) => EditorRuleError(EditorRule.operation, code, path, ids);

EditDecision _reject(NoteDocument document, EditorRuleError error) =>
    EditDecision._(document, error, null, null);

/// A builder rejection that keeps the operation the user asked for.
final class _Rejected implements Exception {
  _Rejected(this.error, this.operation);
  final EditorRuleError error;
  final JsonObject operation;
}

JsonObject _object(Object? value, String path) =>
    value is JsonObject ? value : throw _opError('invalid_operation', path);

String _kind(JsonObject step, String path) => switch (step['op']) {
  final String k
      when const [
        'add',
        'replace',
        'update',
        'delete',
        'page',
        'batch',
      ].contains(k) =>
    k,
  _ => throw _opError('invalid_operation', '$path.op'),
};

void _allow(JsonObject value, List<String> keys, String path) {
  final unknown = value.keys.where((k) => !keys.contains(k)).toList()..sort();
  if (unknown.isNotEmpty) {
    throw _opError('invalid_operation', '$path.${unknown.first}');
  }
}

int _find(List<Object?> items, String id, String path) {
  final i = items.indexWhere((it) => it is Map && it['id'] == id);
  if (i < 0) throw _opError('missing_item', path, [id]);
  return i;
}

Object? _jsonCopy(Object? value) =>
    value == null ? null : jsonDecode(jsonEncode(value));

/// A schema error of the working copy. `out_of_bounds` belongs to `page_bounds`.
EditorRuleError _schemaError(DocumentFormatException e, JsonObject document) {
  final rule = e.code == 'out_of_bounds'
      ? EditorRule.pageBounds
      : EditorRule.documentSchema;
  final match = RegExp(r'^items\[(\d+)\]').firstMatch(e.path);
  final items = document['items'];
  final index = match == null ? -1 : int.parse(match[1]!);
  final item = items is List && index >= 0 && index < items.length
      ? items[index]
      : null;
  final id = item is Map ? item['id'] : null;
  return EditorRuleError(rule, e.code, e.path, [if (id is String) id]);
}
