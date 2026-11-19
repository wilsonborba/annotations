/// Which editor a note opens in on a device (annotations#35, A2/F1 platform
/// roles, closure answer on Android tablets).
///
/// - Full writers (macOS, Linux, iPad, Android tablets) edit paper notes
///   with every tool.
/// - Phones (Android phones, iPhone) write simple typed notes: headings,
///   paragraphs and lists with the text formatting. Everything else opens
///   read-only: content is never flattened, converted or removed.
/// - The browser reads.
/// A typed note with tables, figures, handwriting or cards opens read-only
/// everywhere until a full typed editor exists.
library;

import '../../core/platform_profile.dart';
import '../models/note_document.dart';

enum NoteView {
  /// The paper editor with every tool.
  paper,

  /// The simple typed editor.
  typed,

  /// Reading only; nothing is saved.
  readOnly,
}

/// Block kinds of a simple typed note.
const simpleTypedBlockKinds = {'heading', 'paragraph', 'list'};

/// Whether [document] is a simple typed note.
bool isSimpleTyped(NoteDocument document) =>
    document is TypedDocument &&
    document.blocks.every(
      (b) => simpleTypedBlockKinds.contains(b.toJson()['kind']),
    );

/// The view of [document] on a device of [profile].
NoteView noteViewFor(PlatformProfile profile, NoteDocument document) {
  if (profile == PlatformProfile.browser) return NoteView.readOnly;
  if (document is TypedDocument) {
    return isSimpleTyped(document) ? NoteView.typed : NoteView.readOnly;
  }
  if (document is PaperDocument && profile == PlatformProfile.fullWriter) {
    return NoteView.paper;
  }
  return NoteView.readOnly;
}
