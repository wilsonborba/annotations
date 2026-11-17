/// The binding of the text engine to one text item of an open document
/// (annotations#23 with the contracts of annotations#20 and annotations#21).
///
/// Every committed change of the engine (typing, deleting, paste, cut,
/// formatting, IME commit and programmatic changes) becomes a type C candidate
/// [EditorRules.editText] with the height that the engine measured, and only
/// an accepted candidate enters the document: through [NotesEditor.apply] with
/// a [HistoryCommand] in Notes, or [InstantEditor.apply] in Instant (no
/// history). A rejected candidate changes nothing and creates no step.
library;

import '../../dal/local/text_engine.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'note_history.dart';

final class TextItemBinding implements TextBinding {
  TextItemBinding(this.session, this.itemId, this.engine);

  final EditorSession session;
  final String itemId;
  final TextEngine engine;

  /// The decision of the last commit attempt, kept for the UI: after a
  /// rejection it has the rule error and the requested spans (B2 feedback).
  EditDecision? lastDecision;

  TextItem get _item {
    final document = session.document;
    if (document is! PaperDocument) {
      throw StateError('Text items exist only in paper documents.');
    }
    for (final item in document.items) {
      if (item is TextItem && item.id == itemId) return item;
    }
    throw StateError('No text item with this id.');
  }

  @override
  TextSpans get spans => [for (final span in _item.spans) span.toJson()];

  @override
  TextCommit commit(TextChange change) {
    final width = _item.bounds!.width;
    final num height;
    try {
      // Validates the candidate against the adapter before it is measured.
      engine.load(change.spans);
      height = engine.measureHeight(change.spans, width);
    } on TextContentException catch (error) {
      lastDecision = null;
      return TextCommit.rejected(change, error);
    }
    EditDecision build(EditorRules rules, NoteDocument document) =>
        rules.editText(
          document,
          itemId,
          spans: change.spans,
          measuredHeight: height,
        );
    final decision = lastDecision = switch (session) {
      final NotesEditor notes => notes.apply(_command(change), build),
      final InstantEditor instant => instant.apply(build),
    };
    return decision.accepted
        ? TextCommit.accepted(change)
        : TextCommit.rejected(change, decision.error!);
  }

  HistoryCommand _command(TextChange change) => switch (change.kind) {
    TextChangeKind.typing => HistoryCommand.text(
      itemId,
      TextInput.typing(change.offset, change.text ?? ''),
    ),
    TextChangeKind.deleting => HistoryCommand.text(
      itemId,
      TextInput.deleting(change.offset, change.length),
    ),
    TextChangeKind.replacing => HistoryCommand.text(
      itemId,
      TextInput.replacing(change.offset, change.length),
    ),
    TextChangeKind.composition => HistoryCommand.text(
      itemId,
      TextInput.composition(change.offset, change.length),
    ),
    TextChangeKind.formatting => HistoryCommand(CommandKind.formatting),
  };

  NotesEditor? get _notes => switch (session) {
    final NotesEditor notes => notes,
    InstantEditor() => null,
  };

  @override
  bool undo() => _notes?.undo().moved ?? false;

  @override
  bool redo() => _notes?.redo().moved ?? false;

  @override
  bool get canUndo => _notes?.canUndo ?? false;

  @override
  bool get canRedo => _notes?.canRedo ?? false;
}
