/// Editor sessions of an open document, and the one Undo and Redo history of a
/// Notes document (B2 G2, B6.5, B11).
///
/// A Notes document has exactly one history for all its objects: text,
/// formatting, ink, points, erasing, move, resize, group, ungroup, cards,
/// removal, paste and page changes. Only an accepted [EditDecision] of
/// [EditorRules] enters it; a rejected candidate never creates a step. The
/// history lives in memory with its [NotesEditor]: it is empty when the note is
/// opened again, and nothing about it is written into the document.
///
/// Instant has no history at all: [EditorSession.open] gives an Instant room an
/// [InstantEditor], which has no Undo, no Redo and no step counts.
///
/// A text engine never keeps its own undo stack. Its local history is turned
/// off, and every committed text change, formatting change, paste and IME
/// commit goes through [NotesEditor.apply] (or a [NotesGesture]) with a
/// [HistoryCommand.text] or [CommandKind.formatting] command. Undo and Redo
/// keys of the engine call [NotesEditor.undo] and [NotesEditor.redo].
library;

import '../../core/note_limits.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';

/// What a history step did. It labels the step; the change itself is the
/// difference between the document states before and after the command.
enum CommandKind {
  text,
  formatting,
  ink,
  points,
  erase,
  move,
  resize,
  group,
  ungroup,
  card,
  remove,
  paste,
  duplicate,
  page,
}

enum TextInputKind { typing, deleting, replacing, composition }

/// One committed text change, as the text engine reports it. Offsets and
/// lengths are positions in the plain text of the item, in the unit of the
/// engine (the same unit for every input).
final class TextInput {
  /// [text] was typed at [offset].
  TextInput.typing(this.offset, String this.text)
    : kind = TextInputKind.typing,
      length = text.length;

  /// [length] characters were deleted from [offset] (Backspace or Delete).
  TextInput.deleting(this.offset, this.length)
    : kind = TextInputKind.deleting,
      text = null;

  /// Any other text change: paste, cut, a replaced selection, a correction.
  TextInput.replacing(this.offset, this.length)
    : kind = TextInputKind.replacing,
      text = null;

  /// The commit of an IME composition. Composing updates are not commits.
  TextInput.composition(this.offset, this.length)
    : kind = TextInputKind.composition,
      text = null;

  final TextInputKind kind;
  final int offset, length;
  final String? text;
}

/// The label of a command that the history records.
final class HistoryCommand {
  /// Any command except text input. Text uses [HistoryCommand.text].
  HistoryCommand(this.kind) : itemId = null, input = null {
    if (kind == CommandKind.text) {
      throw ArgumentError.value(kind, 'kind', 'use HistoryCommand.text');
    }
  }

  /// Committed text input in the text item [itemId].
  HistoryCommand.text(String this.itemId, TextInput this.input)
    : kind = CommandKind.text;

  final CommandKind kind;
  final String? itemId;
  final TextInput? input;
}

/// The result of an Undo or Redo: whether the document [moved], the rule
/// error if the restored state was not accepted, and the counts for the short
/// notice (steps back and steps forward).
final class HistoryMove {
  const HistoryMove._(
    this.moved,
    this.error,
    this.stepsBack,
    this.stepsForward,
  );
  final bool moved;
  final EditorRuleError? error;
  final int stepsBack, stepsForward;
}

enum EditorMode { notes, instant }

/// Builds a candidate edit from the current document, with the editor rules.
typedef EditBuilder =
    EditDecision Function(EditorRules rules, NoteDocument document);

/// The editor of one open document.
sealed class EditorSession {
  EditorSession._(this._document, this.rules);

  /// Opens [document] for editing: an Instant room gets an [InstantEditor]
  /// without history, a note gets a [NotesEditor] with an empty history.
  static EditorSession open(
    NoteDocument document, {
    EditorRules rules = const EditorRules(),
    HistorySettings history = const HistorySettings(),
    DateTime Function() clock = DateTime.now,
  }) => document is InstantRoomDocument
      ? InstantEditor(document, rules: rules)
      : NotesEditor(document, rules: rules, settings: history, clock: clock);

  NoteDocument _document;
  final EditorRules rules;

  EditorMode get mode;

  /// The current document, the last accepted state.
  NoteDocument get document => _document;
}

/// Undo and Redo, offered only by the Notes editor.
abstract interface class UndoRedo {
  int get stepsBack;
  int get stepsForward;
  bool get canUndo;
  bool get canRedo;
  HistoryMove undo();
  HistoryMove redo();
}

/// An Instant room editor. Instant has no Undo and no Redo: an accepted edit
/// replaces the document and cannot be taken back.
final class InstantEditor extends EditorSession {
  InstantEditor(
    InstantRoomDocument document, {
    EditorRules rules = const EditorRules(),
  }) : super._(document, rules);

  @override
  EditorMode get mode => EditorMode.instant;

  /// Runs [edit] on the current document and keeps an accepted result.
  EditDecision apply(EditBuilder edit) {
    final decision = edit(rules, _document);
    if (decision.accepted) _document = decision.document;
    return decision;
  }
}

/// The editor of one open Notes document, with its one history.
///
/// One completed gesture is one step (B6.5, closure review): one drag of a
/// point, one move, one resize, one stroke, one live erase gesture. A gesture
/// whose candidate is only previewed (a drag) is applied once on release with
/// [apply]. A gesture that changes the document while it runs (live erasing,
/// or an IME composition the engine keeps in the document) uses [begin]; its
/// edits become one step at [NotesGesture.end].
///
/// Text input coalescing rule. A committed text input joins the newest step
/// only when all of these hold:
/// 1. the newest step is text input of the same text item and was the last
///    thing that happened (no other command, gesture, Undo or Redo since);
/// 2. both inputs are typing, or both are deleting; replacing (paste, cut,
///    corrections) and IME commits always start their own step;
/// 3. the input continues where the previous one ended: typing starts at the
///    end of the previous typed text; deleting ends where the previous
///    deletion started (Backspace) or starts at the same offset (Delete);
/// 4. it comes within [HistorySettings.textMergeWindow] of the previous input;
/// 5. typing does not start a new word: text that begins with a non-space
///    character after typed text that ended with a space or line break starts
///    a new step.
/// An IME composition becomes one step only at its commit: composing updates
/// never create a step, and the commit is never joined with other input.
final class NotesEditor extends EditorSession implements UndoRedo {
  NotesEditor(
    NoteDocument document, {
    EditorRules rules = const EditorRules(),
    this.settings = const HistorySettings(),
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock,
       super._(document, rules) {
    if (document is InstantRoomDocument) {
      throw ArgumentError.value(
        document.schema.name,
        'document',
        'Instant has no history',
      );
    }
  }

  final HistorySettings settings;
  final DateTime Function() _clock;
  final _undo = <_Step>[];
  final _redo = <_Step>[];
  NotesGesture? _gesture;

  /// True while the newest step may still take text input (rule 1).
  bool _textOpen = false;

  @override
  EditorMode get mode => EditorMode.notes;

  @override
  int get stepsBack => _undo.length;
  @override
  int get stepsForward => _redo.length;
  @override
  bool get canUndo => _gesture == null && _undo.isNotEmpty;
  @override
  bool get canRedo => _gesture == null && _redo.isNotEmpty;

  /// Runs [edit] on the current document. An accepted change becomes one step
  /// labeled [command] (or joins the newest text step, see the class rule). A
  /// rejected candidate changes nothing and creates no step.
  EditDecision apply(HistoryCommand command, EditBuilder edit) {
    _idle();
    final before = _document;
    final decision = edit(rules, before);
    if (decision.accepted) _record(command, before, decision.document);
    return decision;
  }

  /// Starts a gesture that changes the document while it runs. Until it ends,
  /// no other edit, Undo or Redo is possible.
  NotesGesture begin(HistoryCommand command) {
    _idle();
    _textOpen = false;
    return _gesture = NotesGesture._(this, command, _document);
  }

  @override
  HistoryMove undo() => _move(_undo, _redo, forward: false);

  @override
  HistoryMove redo() => _move(_redo, _undo, forward: true);

  HistoryMove _move(List<_Step> from, List<_Step> to, {required bool forward}) {
    _idle();
    _textOpen = false;
    if (from.isEmpty) {
      return HistoryMove._(false, null, stepsBack, stepsForward);
    }
    final step = from.last;
    final decision = rules.check(
      NoteDocument.fromJson(
        step.applyTo(_document.toJson(), forward: forward),
        schema: _document.schema,
      ),
    );
    if (!decision.accepted) {
      return HistoryMove._(false, decision.error, stepsBack, stepsForward);
    }
    to.add(from.removeLast());
    _document = decision.document;
    return HistoryMove._(true, null, stepsBack, stepsForward);
  }

  void _idle() {
    if (_gesture != null) throw StateError('A gesture is still open.');
  }

  void _record(HistoryCommand command, NoteDocument before, NoteDocument next) {
    _document = next;
    final now = _clock();
    final step = _Step.diff(command, before.toJson(), next.toJson(), now);
    if (step == null) return;
    _redo.clear();
    if (_textOpen && _undo.isNotEmpty && _joins(_undo.last, command, now)) {
      _undo.last.absorb(step);
    } else {
      _undo.add(step);
      while (_undo.length > settings.maxSteps) {
        _undo.removeAt(0);
      }
    }
    final kind = command.input?.kind;
    _textOpen = kind == TextInputKind.typing || kind == TextInputKind.deleting;
  }

  bool _joins(_Step top, HistoryCommand next, DateTime now) {
    final a = top.command.input, b = next.input;
    if (a == null || b == null || a.kind != b.kind) return false;
    if (top.command.itemId != next.itemId) return false;
    if (now.difference(top.at) > settings.textMergeWindow) return false;
    return switch (b.kind) {
      TextInputKind.typing =>
        b.offset == a.offset + a.length &&
            !(_space(a.text!, last: true) && !_space(b.text!, last: false)),
      TextInputKind.deleting =>
        b.offset + b.length == a.offset || b.offset == a.offset,
      _ => false,
    };
  }
}

bool _space(String text, {required bool last}) =>
    text.isNotEmpty &&
    RegExp(r'\s').hasMatch(last ? text[text.length - 1] : text[0]);

/// A gesture of a [NotesEditor] that changes the document while it runs. Its
/// accepted edits become one step at [end].
final class NotesGesture {
  NotesGesture._(this._editor, this.command, this._start);
  final NotesEditor _editor;
  final HistoryCommand command;
  final NoteDocument _start;
  bool _open = true;

  /// Runs [edit] on the current document; an accepted change is shown at once
  /// but is not a step yet.
  EditDecision apply(EditBuilder edit) {
    _check();
    final decision = edit(_editor.rules, _editor._document);
    if (decision.accepted) _editor._document = decision.document;
    return decision;
  }

  /// Completes the gesture: all its changes become one step. Returns false when
  /// the document did not change, then no step is created.
  bool end() {
    _close();
    final before = _editor.stepsBack, forward = _editor.stepsForward;
    _editor._record(command, _start, _editor._document);
    return _editor.stepsBack != before || _editor.stepsForward != forward;
  }

  /// Drops the changes of the gesture and restores the state at its start. No
  /// step is created. When the UI cancels a gesture is decided by the UI.
  void cancel() {
    _close();
    _editor._document = _start;
  }

  void _check() {
    if (!_open) throw StateError('The gesture has ended.');
  }

  void _close() {
    _check();
    _open = false;
    _editor._gesture = null;
  }
}

/// The change of one step: the values before and after it of every top-level
/// field and every item that changed, and the item order when it changed.
/// Items are matched by id, so Undo and Redo touch only what the step changed.
final class _Step {
  _Step._(
    this.command,
    this.at,
    this.fields,
    this.items,
    this.orderBefore,
    this.orderAfter,
  );

  HistoryCommand command;
  DateTime at;
  final Map<String, _Change> fields;
  final Map<String, _Change> items;
  List<String>? orderBefore, orderAfter;

  /// The step from [before] to [after], or null when nothing changed.
  static _Step? diff(
    HistoryCommand command,
    Map<String, Object?> before,
    Map<String, Object?> after,
    DateTime at,
  ) {
    final fields = <String, _Change>{};
    final items = <String, _Change>{};
    List<String>? orderBefore, orderAfter;
    final b = _byId(before['items']), a = _byId(after['items']);
    final keyed = b != null && a != null;
    for (final key in {...before.keys, ...after.keys}) {
      if (keyed && key == 'items') continue;
      final x = before.containsKey(key) ? before[key] : _absent;
      final y = after.containsKey(key) ? after[key] : _absent;
      if (!_same(x, y)) fields[key] = _Change(x, y);
    }
    if (b != null && a != null) {
      for (final id in {...b.keys, ...a.keys}) {
        if (!_same(b[id], a[id])) items[id] = _Change(b[id], a[id]);
      }
      if (!_same(b.keys.toList(), a.keys.toList())) {
        orderBefore = b.keys.toList();
        orderAfter = a.keys.toList();
      }
    }
    if (fields.isEmpty && items.isEmpty && orderBefore == null) return null;
    return _Step._(command, at, fields, items, orderBefore, orderAfter);
  }

  /// Adds the newer step [next] to this one (text coalescing).
  void absorb(_Step next) {
    void merge(Map<String, _Change> mine, Map<String, _Change> theirs) {
      for (final MapEntry(:key, :value) in theirs.entries) {
        final old = mine[key];
        mine[key] = _Change(
          old == null ? value.before : old.before,
          value.after,
        );
      }
    }

    merge(fields, next.fields);
    merge(items, next.items);
    orderBefore ??= next.orderBefore;
    orderAfter = next.orderAfter ?? orderAfter;
    command = next.command;
    at = next.at;
  }

  /// The document JSON after this step is applied ([forward]) or taken back
  /// to [current], which must be the state at the other end of the step.
  Map<String, Object?> applyTo(
    Map<String, Object?> current, {
    required bool forward,
  }) {
    Object? source(_Change c) => forward ? c.before : c.after;
    Object? target(_Change c) => forward ? c.after : c.before;
    void expectSame(Object? actual, Object? expected) {
      if (!_same(actual, expected)) {
        throw StateError('The document changed outside its history.');
      }
    }

    for (final MapEntry(:key, value: change) in fields.entries) {
      expectSame(
        current.containsKey(key) ? current[key] : _absent,
        source(change),
      );
      final value = target(change);
      if (identical(value, _absent)) {
        current.remove(key);
      } else {
        current[key] = _copy(value);
      }
    }
    if (items.isEmpty && orderBefore == null) return current;
    final byId = _byId(current['items']);
    if (byId == null) throw StateError('The document has no keyed items.');
    for (final MapEntry(:key, value: change) in items.entries) {
      expectSame(byId[key], source(change));
    }
    final order = (forward ? orderAfter : orderBefore) ?? byId.keys.toList();
    current['items'] = [
      for (final id in order)
        _copy(items.containsKey(id) ? target(items[id]!) : byId[id]),
    ];
    return current;
  }
}

final class _Change {
  _Change(this.before, this.after);

  /// JSON values; [_absent] (top-level fields) or null (items) when missing.
  final Object? before, after;
}

const Object _absent = _Absent();

final class _Absent {
  const _Absent();
}

/// Items by id in document order, or null when the value is not a list of
/// objects with unique string ids (then it is kept as one field).
Map<String, Map<String, Object?>>? _byId(Object? items) {
  if (items is! List) return null;
  final out = <String, Map<String, Object?>>{};
  for (final item in items) {
    if (item is! Map<String, Object?>) return null;
    final id = item['id'];
    if (id is! String || out.containsKey(id)) return null;
    out[id] = item;
  }
  return out;
}

/// Deep JSON equality that keeps int and double apart, as the document does.
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || !_same(value, b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b && (a is int) == (b is int);
  return a == b;
}

Object? _copy(Object? value) => switch (value) {
  final Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries) key: _copy(value),
  },
  final List<Object?> l => [for (final v in l) _copy(v)],
  _ => value,
};
