/// Flutter Quill behind the Annotations text port (annotations#23).
///
/// Chosen engine: flutter_quill 11.5.0, pinned exactly (the newest release
/// that the Flutter 3.41 SDK of the workspace resolves; 11.5.1 and later need
/// a newer SDK). Quill types stay in this file: the domain sees only
/// [TextEngine], [TextContent], [TextBinding] and the stored span format.
///
/// Mapping of the stored span fields to Quill attributes:
/// - `bold`, `italic`, `strikethrough` true: the Quill keys `bold`, `italic`,
///   `strike`. Quill renders any present inline key, so an explicit false is
///   kept in its own ignored key (`annotations-bold-off`, ...).
/// - `color` #RRGGBBAA: the Quill `color` #AARRGGBB (the same digits moved,
///   letter case kept).
/// - `size`: the Quill `size` with the same number.
/// Every other Quill attribute or embed (headings, lists, links, images) is
/// unsupported: a candidate that has one is rejected, except the links that
/// Quill adds by itself when a typed word looks like a URL, which are removed.
library;

// The overridden Quill controller methods carry experimental parameters and
// members of Quill 11.5.0 (shouldNotifyListeners, clipboardSelection); they are
// passed through unchanged.
// ignore_for_file: experimental_member_use

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import 'text_engine.dart';

const _flags = {'bold': 'bold', 'italic': 'italic', 'strikethrough': 'strike'};
const _off = {
  'bold': 'annotations-bold-off',
  'italic': 'annotations-italic-off',
  'strikethrough': 'annotations-strikethrough-off',
};
final _storedColor = RegExp(r'^#[0-9A-Fa-f]{8}$');

/// The default text style of a text item: the bundled Ubuntu Sans with the
/// bundled Thai fallback. The editor UI passes its final style to
/// [QuillTextEngine]; measuring and the editor must use the same style.
///
/// The fonts are declared in this package, so an app registers them as
/// `packages/annotations_shared/<family>`; [TextStyle.package] adds that
/// prefix to the family and the fallback, like the design system theme.
const annotationsTextStyle = TextStyle(
  fontFamily: 'Ubuntu Sans',
  fontFamilyFallback: ['IBM Plex Sans Thai'],
  package: 'annotations_shared',
  fontSize: 16,
  color: Color(0xFF000000),
);

final class QuillTextEngine implements TextEngine {
  const QuillTextEngine({this.style = annotationsTextStyle});

  /// The paragraph style of every line, for the editor and for measuring.
  final TextStyle style;

  @override
  String get name => 'flutter_quill';

  @override
  String get version => '11.5.0';

  /// Quill styles that lay out text exactly like [measureHeight]: no block
  /// spacing, no line spacing, the paragraph [style] on every line.
  DefaultStyles get styles => DefaultStyles(
    paragraph: DefaultTextBlockStyle(
      style,
      HorizontalSpacing.zero,
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
    bold: const TextStyle(fontWeight: FontWeight.bold),
    italic: const TextStyle(fontStyle: FontStyle.italic),
    strikeThrough: const TextStyle(decoration: TextDecoration.lineThrough),
  );

  @override
  QuillContent load(List<Object?> spans) => QuillContent._(document(spans));

  /// A Quill document of [spans] with the Quill history turned off: the one
  /// Notes history of annotations#21 owns Undo and Redo.
  Document document(List<Object?> spans) =>
      _quiet(Document.fromDelta(spansToDelta(spans)));

  @override
  num measureHeight(List<Object?> spans, num width) {
    spansToDelta(spans); // Validates the spans.
    var lines = <List<InlineSpan>>[[]];
    for (final raw in spans) {
      final span = raw as Map<String, Object?>;
      final parts = (span['text'] as String).split('\n');
      for (final (i, part) in parts.indexed) {
        if (i > 0) lines.add([]);
        if (part.isNotEmpty) {
          lines.last.add(TextSpan(text: part, style: _inline(span)));
        }
      }
    }
    var height = 0.0;
    for (final line in lines) {
      final painter = TextPainter(
        text: TextSpan(style: style, children: line),
        textDirection: TextDirection.ltr,
        strutStyle: StrutStyle.fromTextStyle(style),
        textScaler: TextScaler.noScaling,
      )..layout(maxWidth: width.toDouble());
      height += painter.height;
      painter.dispose();
    }
    return (height * 100).ceil() / 100;
  }

  // The inline style that Quill gives a text node (TextLine of Quill 11.5.0).
  TextStyle _inline(Map<String, Object?> span) {
    var result = const TextStyle();
    if (span['bold'] == true) result = result.merge(styles.bold);
    if (span['italic'] == true) result = result.merge(styles.italic);
    if (span['strikethrough'] == true) {
      result = result.merge(styles.strikeThrough);
    }
    final size = span['size'] as num?;
    if (size != null) result = result.merge(TextStyle(fontSize: size * 1.0));
    final color = span['color'] as String?;
    if (color != null) {
      result = result.merge(
        TextStyle(
          color: Color(int.parse(_quillColor(color).substring(1), radix: 16)),
        ),
      );
    }
    return result;
  }
}

Document _quiet(Document document) {
  document.history.ignoreChange = true;
  return document;
}

String _quillColor(String stored) =>
    '#${stored.substring(7, 9)}${stored.substring(1, 7)}';
String _storedColorOf(String quill) =>
    '#${quill.substring(3, 9)}${quill.substring(1, 3)}';

/// Stored spans to a Quill document delta (with the closing line break).
Delta spansToDelta(List<Object?> spans) {
  final delta = Delta();
  for (final (i, raw) in spans.indexed) {
    final path = 'spans[$i]';
    if (raw is! Map<String, Object?>) {
      throw TextContentException('invalid_type', path);
    }
    final attributes = <String, Object?>{};
    for (final MapEntry(:key, :value) in raw.entries) {
      final at = '$path.$key';
      switch (key) {
        case 'text':
          if (value is! String) throw TextContentException('invalid_type', at);
        case 'bold' || 'italic' || 'strikethrough':
          if (value == null) continue;
          if (value is! bool) throw TextContentException('invalid_type', at);
          attributes[value ? _flags[key]! : _off[key]!] = value;
        case 'color':
          if (value == null) continue;
          if (value is! String || !_storedColor.hasMatch(value)) {
            throw TextContentException('invalid_color', at);
          }
          attributes['color'] = _quillColor(value);
        case 'size':
          if (value == null) continue;
          if (value is! num || !value.isFinite || value <= 0) {
            throw TextContentException('invalid_size', at);
          }
          attributes['size'] = value;
        default:
          throw TextContentException('unsupported_field', at);
      }
    }
    final text = raw['text'];
    if (text is! String) {
      throw TextContentException('missing_field', '$path.text');
    }
    if (text.isNotEmpty) {
      delta.insert(text, attributes.isEmpty ? null : attributes);
    }
  }
  return delta..insert('\n');
}

/// A Quill document delta to stored spans in canonical form: the closing line
/// break removed, adjacent spans with equal formatting joined, no empty spans.
TextSpans deltaToSpans(Delta delta) {
  final spans = <Map<String, Object?>>[];
  final operations = delta.toList();
  for (final (i, op) in operations.indexed) {
    final path = 'ops[$i]';
    if (!op.isInsert) throw TextContentException('not_a_document', path);
    final data = op.data;
    if (data is! String) throw TextContentException('unsupported_embed', path);
    var text = data;
    if (i == operations.length - 1) {
      if (!text.endsWith('\n')) {
        throw TextContentException('not_a_document', path);
      }
      text = text.substring(0, text.length - 1);
    }
    // The formatting of every operation is checked, also of an empty one (a
    // line break with a block format such as a heading or a list).
    final fields = _fields(op.attributes, path);
    if (text.isEmpty) continue;
    final span = <String, Object?>{'text': text, ...fields};
    final last = spans.isEmpty ? null : spans.last;
    if (last != null && _sameFormat(last, span)) {
      last['text'] = '${last['text']}$text';
    } else {
      spans.add(span);
    }
  }
  return spans;
}

Map<String, Object?> _fields(Map<String, dynamic>? attributes, String path) {
  final raw = attributes ?? const {};
  final fields = <String, Object?>{};
  for (final key in raw.keys) {
    if (!_flags.containsValue(key) &&
        !_off.containsValue(key) &&
        key != 'color' &&
        key != 'size') {
      throw TextContentException('unsupported_format', '$path.$key');
    }
  }
  for (final field in ['bold', 'italic', 'strikethrough']) {
    if (raw[_flags[field]] == true) {
      fields[field] = true;
    } else if (raw[_off[field]] == false) {
      fields[field] = false;
    } else if (raw.containsKey(_flags[field]) || raw.containsKey(_off[field])) {
      throw TextContentException('invalid_format', '$path.$field');
    }
  }
  final color = raw['color'];
  if (color != null) {
    if (color is! String || !RegExp(r'^#[0-9A-Fa-f]{8}$').hasMatch(color)) {
      throw TextContentException('unsupported_color', '$path.color');
    }
    fields['color'] = _storedColorOf(color);
  }
  final size = raw['size'];
  if (size != null) {
    if (size is! num || !size.isFinite || size <= 0) {
      throw TextContentException('unsupported_size', '$path.size');
    }
    fields['size'] = size;
  }
  return fields;
}

bool _sameFormat(Map<String, Object?> a, Map<String, Object?> b) {
  for (final field in supportedSpanFields.skip(1)) {
    if (a[field] != b[field] || a.containsKey(field) != b.containsKey(field)) {
      return false;
    }
  }
  return true;
}

Attribute<Object?> _attribute(TextFormat format) => switch (format.field) {
  'bold' =>
    format.value == true
        ? Attribute.bold
        : Attribute.clone(Attribute.bold, null),
  'italic' =>
    format.value == true
        ? Attribute.italic
        : Attribute.clone(Attribute.italic, null),
  'strikethrough' =>
    format.value == true
        ? Attribute.strikeThrough
        : Attribute.clone(Attribute.strikeThrough, null),
  'color' =>
    format.value == null
        ? Attribute.clone(Attribute.color, null)
        : _validColor(format.value),
  'size' =>
    format.value == null
        ? Attribute.clone(Attribute.size, null)
        : _validSize(format.value),
  _ => throw TextContentException('unsupported_format', format.field),
};

Attribute<Object?> _validColor(Object? value) {
  if (value is! String || !_storedColor.hasMatch(value)) {
    throw const TextContentException('invalid_color', 'color');
  }
  return ColorAttribute(_quillColor(value));
}

Attribute<Object?> _validSize(Object? value) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw const TextContentException('invalid_size', 'size');
  }
  return Attribute.fromKeyValue(Attribute.size.key, value)!;
}

// Quill turns a typed or pasted URL into a link by itself. Links are not a
// supported span format, so these automatic links are removed again.
void _removeLinks(Document document) {
  var offset = 0;
  final ranges = <(int, int)>[];
  for (final op in document.toDelta().toList()) {
    final length = op.length ?? 0;
    if (op.attributes?.containsKey(Attribute.link.key) ?? false) {
      ranges.add((offset, length));
    }
    offset += length;
  }
  for (final (start, length) in ranges) {
    document.format(start, length, Attribute.clone(Attribute.link, null));
  }
}

/// Quill content of one text item, without a widget.
final class QuillContent implements TextContent {
  QuillContent._(this._document);
  final Document _document;

  Delta get delta => _document.toDelta();

  @override
  String get plainText {
    final text = _document.toPlainText();
    return text.substring(0, text.length - 1);
  }

  @override
  TextSpans toSpans() => deltaToSpans(_document.toDelta());

  Document _copy() => _quiet(Document.fromDelta(_document.toDelta()));

  void _range(int offset, int length) {
    if (offset < 0 || length < 0 || offset + length > plainText.length) {
      throw RangeError.range(offset + length, 0, plainText.length);
    }
  }

  @override
  QuillContent replaced(int offset, int length, String text) {
    _range(offset, length);
    final copy = _copy()..replace(offset, length, text);
    _removeLinks(copy);
    return QuillContent._(copy);
  }

  @override
  QuillContent formatted(int offset, int length, TextFormat format) {
    _range(offset, length);
    final attribute = _attribute(format);
    return QuillContent._(_copy()..format(offset, length, attribute));
  }
}

/// The composing range of the platform text input of a mounted [QuillEditor],
/// for [GuardedQuillController.composingRange].
TextRange Function() quillComposingRange(GlobalKey<QuillEditorState> editor) =>
    () {
      final Object? state = editor.currentState?.editableTextKey.currentState;
      if (state is! TextInputClient) return TextRange.empty;
      return state.currentTextEditingValue?.composing ?? TextRange.empty;
    };

/// The text offset under the [global] position in a mounted [QuillEditor],
/// or null when the editor is not mounted. A click that opens a text block
/// puts the cursor there.
int? quillOffsetAt(GlobalKey<QuillEditorState> editor, Offset global) => editor
    .currentState
    ?.editableTextKey
    .currentState
    ?.renderEditor
    .getPositionForOffset(global)
    .offset;

/// A Quill controller whose every mutation path goes through the
/// [TextBinding] before it is kept (type C guard and the one history).
///
/// - Typing, deleting, Tab, programmatic `replaceText`, `clear` and setting
///   `document`: one candidate per call. Nested Quill calls (paste styles,
///   toggled styles) are part of the outer candidate.
/// - Paste (plain text, or the rich text that this editor copied) and cut:
///   [TextChangeKind.replacing]. A rejected paste keeps its text in
///   [lastRejection].
/// - Formatting (keyboard shortcuts, `formatText`, `formatSelection`,
///   `formatTextStyle`, indent): [TextChangeKind.formatting]. Unsupported
///   formats such as lists and headings are rejected.
/// - IME: composing updates (while [composingRange] is not empty) are shown
///   but are not commits and are never cut. At the commit the whole
///   composition is one candidate [TextChangeKind.composition]; when it is
///   rejected the composed text is kept in [lastRejection].
/// - Undo and Redo (keys and menu actions) call the one history and reload
///   the text from it. The Quill history is off.
/// A rejected candidate reloads the last accepted spans: nothing changes.
class GuardedQuillController extends QuillController {
  GuardedQuillController({
    required this.engine,
    required this.binding,
    this.composingRange,
    this.onRejected,
  }) : super(
         document: engine.document(binding.spans),
         selection: const TextSelection.collapsed(offset: 0),
       );

  final QuillTextEngine engine;
  final TextBinding binding;

  /// The composing range of the platform input; the editor glue sets it with
  /// [quillComposingRange]. Without it every update is a commit.
  TextRange Function()? composingRange;

  /// Called after a rejected candidate, with the kept input.
  void Function(TextCommit rejection)? onRejected;

  /// The last rejected candidate, with its typed, pasted or composed text.
  TextCommit? lastRejection;

  int _depth = 0;
  bool _notify = false;
  _Composition? _composition;

  bool get composing => _composition != null;

  @override
  void notifyListeners() {
    if (_depth > 0) {
      _notify = true;
    } else {
      super.notifyListeners();
    }
  }

  void _batch(void Function() body) {
    _depth++;
    try {
      body();
    } finally {
      _depth--;
    }
    if (_depth == 0 && _notify) {
      _notify = false;
      super.notifyListeners();
    }
  }

  bool _composingNow() {
    final range = composingRange?.call();
    return range != null && range.isValid && !range.isCollapsed;
  }

  String get _plain {
    final text = document.toPlainText();
    return text.substring(0, text.length - 1);
  }

  /// Runs [body] as one candidate. Nested calls join the outer candidate.
  /// Returns false when the candidate was rejected.
  bool _guarded(
    TextChangeKind kind,
    void Function() body, {
    int? offset,
    int? length,
    String? text,
  }) {
    if (_depth > 0) {
      body();
      return true;
    }
    commitComposition();
    final before = document.toDelta();
    final selectionBefore = selection;
    final plainBefore = _plain;
    var accepted = true;
    _batch(() {
      body();
      _removeLinks(document);
      accepted = _finish(
        kind,
        before,
        plainBefore,
        selectionBefore,
        offset: offset,
        length: length,
        text: text,
      );
    });
    return accepted;
  }

  bool _finish(
    TextChangeKind kind,
    Delta before,
    String plainBefore,
    TextSelection selectionBefore, {
    int? offset,
    int? length,
    String? text,
  }) {
    final after = document.toDelta();
    if (after == before) return true;
    final plainAfter = _plain;
    final (start, removed, inserted) = _diff(plainBefore, plainAfter);
    if (plainAfter == plainBefore) {
      kind = TextChangeKind.formatting;
    } else if (kind == TextChangeKind.formatting) {
      kind = TextChangeKind.replacing;
      offset = length = null;
    }
    TextChange change(TextSpans spans) => TextChange(
      kind: kind,
      offset: offset ?? start,
      length:
          length ??
          (kind == TextChangeKind.typing || kind == TextChangeKind.composition
              ? inserted.length
              : removed),
      text: text ?? (inserted.isEmpty ? null : inserted),
      spans: spans,
    );
    TextCommit result;
    try {
      result = binding.commit(change(deltaToSpans(after)));
    } on TextContentException catch (error) {
      result = TextCommit.rejected(change(const []), error);
    }
    if (result.accepted) return true;
    lastRejection = result;
    _reload(selectionBefore);
    onRejected?.call(result);
    return false;
  }

  // Loads the last accepted spans of the binding and keeps the selection.
  void _reload(TextSelection keep) {
    super.document = engine.document(binding.spans);
    final end = _plain.length;
    super.updateSelection(
      keep.copyWith(
        baseOffset: math.min(keep.baseOffset, end),
        extentOffset: math.min(keep.extentOffset, end),
      ),
      ChangeSource.local,
    );
  }

  void _guard(
    TextChangeKind kind,
    void Function() body, {
    int? offset,
    int? length,
  }) => _guarded(kind, body, offset: offset, length: length);

  static TextChangeKind _kindOf(int length, Object? data) {
    final inserts = data is! String || data.isNotEmpty;
    if (length == 0 && inserts) return TextChangeKind.typing;
    if (length > 0 && !inserts) return TextChangeKind.deleting;
    return TextChangeKind.replacing;
  }

  /// Ends an open composition and commits it as one candidate. The editor
  /// glue calls it when the input loses focus; every other entry point calls
  /// it first.
  void commitComposition() {
    final open = _composition;
    if (open == null || _depth > 0) return;
    _composition = null;
    _batch(() {
      _finish(
        TextChangeKind.composition,
        open.before,
        open.plainBefore,
        open.selection,
      );
    });
  }

  @override
  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    bool shouldNotifyListeners = true,
  }) {
    void body() => super.replaceText(
      index,
      len,
      data,
      textSelection,
      ignoreFocus: ignoreFocus,
      shouldNotifyListeners: shouldNotifyListeners,
    );
    if (_depth > 0) {
      body();
      return;
    }
    final composingNow = _composingNow();
    final open = _composition;
    // A change outside the last composing range after the composition ended
    // is new input: the composition is committed first.
    if (open != null &&
        !composingNow &&
        (index > open.end || index + len < open.start)) {
      commitComposition();
    }
    if (composingNow || _composition != null) {
      final composition = _composition ??= _Composition(
        document.toDelta(),
        _plain,
        selection,
      );
      _batch(() {
        body();
        _removeLinks(document);
      });
      if (composingNow) {
        final range = composingRange!();
        composition.start = math.min(composition.start, range.start);
        composition.end = math.max(range.end, index + _length(data));
      } else {
        commitComposition();
      }
      return;
    }
    _guarded(
      _kindOf(len, data),
      body,
      offset: index,
      length: _kindOf(len, data) == TextChangeKind.typing ? _length(data) : len,
      text: data is String && data.isNotEmpty ? data : null,
    );
  }

  static int _length(Object? data) => data is String ? data.length : 1;

  @override
  void replaceTextWithEmbeds(
    int index,
    int len,
    String insertedText,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    bool shouldNotifyListeners = true,
  }) {
    // The selection delegate of Quill sends edits here; the replaceText call
    // inside it is the candidate, the paste styles join it.
    void body() => super.replaceTextWithEmbeds(
      index,
      len,
      insertedText,
      textSelection,
      ignoreFocus: ignoreFocus,
      shouldNotifyListeners: shouldNotifyListeners,
    );
    if (_depth > 0 || _composingNow() || _composition != null) {
      // Composition and nested calls are handled by replaceText.
      body();
      return;
    }
    final kind = _kindOf(len, insertedText);
    _guarded(
      kind,
      body,
      offset: index,
      length: kind == TextChangeKind.typing ? insertedText.length : len,
      text: insertedText.isEmpty ? null : insertedText,
    );
  }

  @override
  void formatText(
    int index,
    int len,
    Attribute? attribute, {
    bool shouldNotifyListeners = true,
  }) => _guard(
    TextChangeKind.formatting,
    () => super.formatText(
      index,
      len,
      attribute,
      shouldNotifyListeners: shouldNotifyListeners,
    ),
    offset: index,
    length: len,
  );

  @override
  void formatTextStyle(int index, int len, Style style) => _guard(
    TextChangeKind.formatting,
    () => super.formatTextStyle(index, len, style),
    offset: index,
    length: len,
  );

  /// The formatting of the selection (for a collapsed selection: of the
  /// next typed text) in the stored span fields: `bold`, `italic` and
  /// `strikethrough` as booleans, `color` as #RRGGBBAA and `size` when set.
  Map<String, Object?> get selectionFormat {
    final attributes = getSelectionStyle().attributes;
    final color = attributes[Attribute.color.key]?.value;
    final size = attributes[Attribute.size.key]?.value;
    final number = size is num ? size : num.tryParse('$size');
    return {
      for (final MapEntry(:key, :value) in _flags.entries)
        key: attributes[value]?.value == true,
      if (color is String && _storedColor.hasMatch(color))
        'color': _storedColorOf(color),
      if (size != null && number != null) 'size': number,
    };
  }

  /// Applies [format] to the current selection only. With a collapsed
  /// selection the format is kept for the next typed text, like Quill does.
  void formatSelectionWith(TextFormat format) =>
      formatSelection(_attribute(format));

  @override
  void indentSelection(bool isIncrease) => _guard(
    TextChangeKind.formatting,
    () => super.indentSelection(isIncrease),
    offset: selection.start,
    length: selection.end - selection.start,
  );

  @override
  void compose(Delta delta, TextSelection textSelection, ChangeSource source) =>
      _guard(
        TextChangeKind.replacing,
        () => super.compose(delta, textSelection, source),
      );

  @override
  set document(Document doc) {
    final length = _plain.length;
    _guarded(
      TextChangeKind.replacing,
      () {
        super.document = _quiet(doc);
      },
      offset: 0,
      length: length,
    );
  }

  @override
  void updateSelection(TextSelection textSelection, ChangeSource source) {
    if (_composition != null && !_composingNow()) commitComposition();
    super.updateSelection(textSelection, source);
  }

  @override
  bool clipboardSelection(bool copy) {
    if (copy) return super.clipboardSelection(copy);
    var result = false;
    _guarded(
      TextChangeKind.replacing,
      () => result = super.clipboardSelection(copy),
    );
    return result;
  }

  /// Pastes plain text, or the rich text that a Quill editor of this app
  /// copied, over the selection as one candidate. External rich text (HTML,
  /// Markdown) and images are not pasted into a text item here.
  @override
  Future<bool> clipboardPaste({void Function()? updateEditor}) async {
    if (readOnly || !selection.isValid) return true;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return false;
    paste(text);
    updateEditor?.call();
    return true;
  }

  /// Pastes [text] over the selection. When it equals the text that this app
  /// copied last, its supported formatting is pasted too.
  bool paste(String text) {
    final start = selection.start, length = selection.end - selection.start;
    final rich = text == pastePlainText && pasteDelta.isNotEmpty;
    return _guarded(
      TextChangeKind.replacing,
      () {
        if (rich) {
          super.compose(
            Delta()
              ..retain(start)
              ..delete(length)
              ..concat(pasteDelta),
            TextSelection.collapsed(offset: start + text.length),
            ChangeSource.local,
          );
        } else {
          super.replaceText(start, length, text, null);
        }
        super.updateSelection(
          TextSelection.collapsed(offset: start + text.length),
          ChangeSource.local,
        );
      },
      offset: start,
      length: length,
      text: text,
    );
  }

  @override
  void undo() {
    commitComposition();
    if (binding.undo()) _batch(() => _reload(selection));
  }

  @override
  void redo() {
    commitComposition();
    if (binding.redo()) _batch(() => _reload(selection));
  }

  @override
  bool get hasUndo => binding.canUndo;

  @override
  bool get hasRedo => binding.canRedo;
}

final class _Composition {
  _Composition(this.before, this.plainBefore, this.selection)
    : start = selection.start,
      end = selection.end;
  final Delta before;
  final String plainBefore;
  final TextSelection selection;
  int start, end;
}

/// The changed range between two plain texts: start, removed length and the
/// inserted text.
(int, int, String) _diff(String a, String b) {
  var start = 0;
  final max = math.min(a.length, b.length);
  while (start < max && a.codeUnitAt(start) == b.codeUnitAt(start)) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start &&
      endB > start &&
      a.codeUnitAt(endA - 1) == b.codeUnitAt(endB - 1)) {
    endA--;
    endB--;
  }
  return (start, endA - start, b.substring(start, endB));
}
