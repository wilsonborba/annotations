/// The port of the one replaceable rich text engine (B11, annotations#23).
///
/// Annotations owns the page, geometry, collisions, history and storage. The
/// text engine only edits the rich text inside one text item. Everything here
/// is engine neutral: the stored format is the span list of the document model
/// (`text`, `bold`, `italic`, `strikethrough`, `color` as #RRGGBBAA, `size`),
/// and no engine type crosses this file. The chosen engine implements
/// [TextEngine] in its own adapter file.
library;

/// The rich text of one item in the stored span format. Every map has `text`
/// and only the supported formatting fields.
typedef TextSpans = List<Map<String, Object?>>;

/// The span fields that the adapter supports, in their stored order.
const supportedSpanFields = [
  'text',
  'bold',
  'italic',
  'strikethrough',
  'color',
  'size',
];

/// Stored text that the engine cannot represent, or engine content that the
/// stored format cannot represent. [code] and [path] never contain text.
final class TextContentException implements Exception {
  const TextContentException(this.code, this.path);
  final String code, path;

  @override
  String toString() => 'TextContentException($code, $path)';
}

/// One inline formatting change of a span of text. A null [value] removes the
/// formatting (for [color] and [size]); for the flags, false removes it.
final class TextFormat {
  const TextFormat.bold(bool on) : field = 'bold', value = on;
  const TextFormat.italic(bool on) : field = 'italic', value = on;
  const TextFormat.strikethrough(bool on) : field = 'strikethrough', value = on;

  /// [color] is #RRGGBBAA, as stored.
  const TextFormat.color(String? color) : field = 'color', value = color;
  const TextFormat.size(num? size) : field = 'size', value = size;

  final String field;
  final Object? value;
}

/// Engine content of one text item, created and changed without an editor
/// widget (typed API content, imports, programmatic edits and tests).
abstract interface class TextContent {
  /// The plain text. Offsets of every change are positions in it (UTF-16
  /// code units, the same unit for all inputs).
  String get plainText;

  /// The content in the stored span format. Adjacent spans with the same
  /// formatting are joined and empty spans are left out (canonical form).
  TextSpans toSpans();

  /// A copy with [length] characters at [offset] replaced by [text].
  TextContent replaced(int offset, int length, String text);

  /// A copy with [format] applied to [length] characters at [offset] only.
  TextContent formatted(int offset, int length, TextFormat format);
}

/// The one text engine behind Annotations.
abstract interface class TextEngine {
  /// Package name and exact version, for the progress record and notices.
  String get name;
  String get version;

  /// Loads stored [spans] into engine content. Throws [TextContentException]
  /// for a field or value that the adapter does not support.
  TextContent load(List<Object?> spans);

  /// The height of [spans] laid out at [width] logical page units with the
  /// same layout as the engine editor, rounded up to 1/100 (the stored block
  /// height, technical decision item 3).
  num measureHeight(List<Object?> spans, num width);
}

/// What kind of committed change the engine reports.
enum TextChangeKind { typing, deleting, replacing, composition, formatting }

/// One change that the engine wants to commit, with the complete candidate
/// content of the item. [offset] and [length] follow the history contract of
/// annotations#21: typing reports the inserted length, deleting and replacing
/// the removed length, a composition the committed length, formatting the
/// formatted length. [text] is the typed, pasted or composed text; it is kept
/// in a rejection so that no input is lost.
final class TextChange {
  const TextChange({
    required this.kind,
    required this.offset,
    required this.length,
    required this.spans,
    this.text,
  });
  final TextChangeKind kind;
  final int offset, length;
  final String? text;
  final TextSpans spans;
}

/// The result of one commit attempt.
final class TextCommit {
  const TextCommit.accepted(this.change) : error = null;
  const TextCommit.rejected(this.change, Object this.error);
  final TextChange change;

  /// The rule error of the rejected candidate (an editor rule error or a
  /// [TextContentException]); null when the change was committed.
  final Object? error;
  bool get accepted => error == null;
}

/// The link of a live engine editor to the Annotations document of one text
/// item. The domain implements it with the editor rules and the one history;
/// the engine calls it for every committed change and never keeps a change
/// that [commit] rejected.
abstract interface class TextBinding {
  /// The item spans in the last accepted document.
  TextSpans get spans;

  /// Checks [change] with the type C guard (editor rules with the measured
  /// height) and commits it to the history when it is accepted.
  TextCommit commit(TextChange change);

  /// Undo and Redo of the one history. Both return false and do nothing when
  /// the session has no history (Instant).
  bool undo();
  bool redo();
  bool get canUndo;
  bool get canRedo;
}
