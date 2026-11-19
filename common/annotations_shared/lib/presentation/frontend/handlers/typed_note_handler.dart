/// The simple typed editor (annotations#35): one Quill document for the
/// headings, paragraphs and lists of a typed note, with the title. Each
/// change is checked by the editor rules, becomes one Notes history step
/// and is saved. Opening without a change saves nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';

import '../../../dal/local/quill_text_engine.dart';
import '../../../dal/local/text_engine.dart';
import '../../../dal/local/typed_blocks.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/note_history.dart';
import 'paper_handler.dart';

/// The paragraph styles of the phone editor.
enum TypedLineStyle { text, heading1, heading2, heading3, bullets, numbers }

class TypedNoteHandler extends ChangeNotifier {
  TypedNoteHandler({required this.paper, String Function()? newId})
    : newId = newId ?? _randomId {
    _load();
    paper.addListener(_paperChanged);
  }

  final PaperHandler paper;
  final String Function() newId;
  final engine = const QuillTextEngine();

  late QuillController controller;
  List<Map<String, Object?>> _blocks = const [];
  bool _writing = false;
  Timer? _pending;

  /// The pause after which typed text becomes one history step and is
  /// saved.
  static const commitDelay = Duration(milliseconds: 500);

  static String _randomId() {
    final r = math.Random.secure();
    return [
      for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16),
    ].map((h) => h.padLeft(2, '0')).join();
  }

  List<Map<String, Object?>> _blocksOf(NoteDocument d) =>
      d is TypedDocument ? [for (final b in d.blocks) b.toJson()] : const [];

  void _load() {
    _blocks = _blocksOf(paper.document);
    final document = Document.fromDelta(blocksToDelta(_blocks));
    controller = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    controller.document.changes.listen((_) {
      // Typing joins into one step until a short pause.
      _pending?.cancel();
      _pending = Timer(commitDelay, commit);
    });
    controller.addListener(notifyListeners);
  }

  /// Undo and Redo change the document from outside: the editor follows.
  void _paperChanged() {
    if (_writing || _pending != null) return;
    final now = _blocksOf(paper.document);
    if (jsonEncode(now) == jsonEncode(_blocks)) return;
    final old = controller;
    final offset = old.selection.baseOffset;
    _load();
    controller.updateSelection(
      TextSelection.collapsed(
        offset: offset.clamp(0, controller.document.length - 1),
      ),
      ChangeSource.local,
    );
    old.dispose();
    notifyListeners();
  }

  /// Writes the editor content to the note now (also on close).
  void commit() {
    _pending?.cancel();
    _pending = null;
    final blocks = documentToBlocks(
      controller.document,
      previous: _blocks,
      newId: newId,
    );
    if (jsonEncode(blocks) == jsonEncode(_blocks)) return;
    final schema = paper.document.schema;
    _writing = true;
    final decision = paper.apply(
      HistoryCommand(CommandKind.text),
      (rules, _) => rules.check(
        NoteDocument.fromJson({'blocks': blocks}, schema: schema),
      ),
    );
    _writing = false;
    if (decision.accepted) _blocks = blocks;
  }

  /// The formatting of the selection, in stored span fields.
  Map<String, Object?> get format => controller.selectionFormat;

  void toggle(String field) {
    final on = format[field] == true;
    controller.formatSelectionWith(switch (field) {
      'bold' => TextFormat.bold(!on),
      'italic' => TextFormat.italic(!on),
      _ => TextFormat.strikethrough(!on),
    });
  }

  void size(num value) => controller.formatSelectionWith(
    TextFormat.size(value == engine.style.fontSize ? null : value),
  );

  void color(String? value) =>
      controller.formatSelectionWith(TextFormat.color(value));

  /// The style of the line at the cursor.
  TypedLineStyle get lineStyle {
    final a = controller.getSelectionStyle().attributes;
    final header = a[Attribute.header.key]?.value;
    final list = a[Attribute.list.key]?.value;
    if (list == 'bullet') return TypedLineStyle.bullets;
    if (list == 'ordered') return TypedLineStyle.numbers;
    return switch (header) {
      1 => TypedLineStyle.heading1,
      2 => TypedLineStyle.heading2,
      3 => TypedLineStyle.heading3,
      _ => TypedLineStyle.text,
    };
  }

  /// Gives the selected lines [style].
  void setLineStyle(TypedLineStyle style) {
    final c = controller;
    c.formatSelection(Attribute.clone(Attribute.header, null));
    c.formatSelection(Attribute.clone(Attribute.list, null));
    switch (style) {
      case TypedLineStyle.heading1:
        c.formatSelection(Attribute.h1);
      case TypedLineStyle.heading2:
        c.formatSelection(Attribute.h2);
      case TypedLineStyle.heading3:
        c.formatSelection(Attribute.h3);
      case TypedLineStyle.bullets:
        c.formatSelection(Attribute.ul);
      case TypedLineStyle.numbers:
        c.formatSelection(Attribute.ol);
      case TypedLineStyle.text:
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    commit();
    paper.removeListener(_paperChanged);
    controller.dispose();
    super.dispose();
  }
}
