/// One live eraser gesture in a Notes document (B2.6, B6.5, closure topic 5).
///
/// The eraser removes ink while the pointer moves; the whole gesture is one
/// history step at [InkEraseGesture.end]. A cancelled pointer gesture restores
/// the document of the gesture start and leaves no step. In dangerous mode the
/// targets are judged against the document of the gesture start, so an object
/// that the gesture reveals is never removed by the same gesture.
library;

import '../../core/ink_settings.dart';
import '../models/ink.dart';
import '../models/note_document.dart';
import 'editor_rules.dart';
import 'note_history.dart';

final class InkEraseGesture {
  /// Starts erasing at [at]. A tap without movement also erases there.
  InkEraseGesture.begin(
    NotesEditor editor, {
    required InkVec at,
    required this.radius,
    this.mode = EraserMode.partialStroke,
    this.dangerous = false,
    required this.newId,
    this.settings = const InkSettings(),
  }) : _gesture = editor.begin(HistoryCommand(CommandKind.erase)),
       _start = editor.document,
       _last = at {
    _step(at);
  }

  final NotesGesture _gesture;
  final NoteDocument _start;
  InkVec _last;

  /// The eraser circle radius in page units.
  final double radius;
  final EraserMode mode;

  /// Delete-anything mode: whole objects, top object only.
  final bool dangerous;
  final String Function() newId;
  final InkSettings settings;

  /// Erases along the move from the previous position to [to].
  EditDecision moveTo(InkVec to) => _step(to);

  /// Ends the gesture: its changes become one Undo step. Returns whether a
  /// step was recorded.
  bool end() => _gesture.end();

  /// Cancels the gesture (pointer cancel): the document returns to the start.
  void cancel() => _gesture.cancel();

  EditDecision _step(InkVec to) {
    final from = _last;
    _last = to;
    return _gesture.apply(
      (rules, document) => dangerous
          ? rules.eraseObjects(
              document,
              start: _start,
              from: from,
              to: to,
              radius: radius,
              settings: settings,
            )
          : rules.erase(
              document,
              from: from,
              to: to,
              radius: radius,
              mode: mode,
              newId: newId,
              settings: settings,
            ),
    );
  }
}
