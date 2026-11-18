/// The flow of typed text blocks on the paper canvas (annotations#27).
///
/// The widgets call this handler; the handler calls the domain: the text
/// blocks service for the free place of a new block, the text item binding
/// for every committed change (type C guard of the editor rules and the one
/// history) and the preferences for the space limit message. The live editor
/// is the text engine adapter (Flutter Quill, annotations#23).
///
/// Space limit feedback (B2.3): a rejected input that does not fit sets
/// [limited] (red block border) and adds one [shakes] tick (the brief
/// shake). The message covers the block area while [messageShown]; OK hides
/// it, Don't show this message again turns it off on this device. The text
/// and the neighbors never change: the rejected input stays in
/// [GuardedQuillController.lastRejection].
library;

import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show ChangeSource, QuillEditorState;

import '../../../dal/local/quill_text_engine.dart';
import '../../../dal/local/text_engine.dart';
import '../../../domain/models/ink.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/object_selection.dart';
import '../../../domain/services/preferences.dart';
import '../../../domain/services/text_blocks.dart';
import '../../../domain/services/text_editing.dart';
import 'paper_handler.dart';

/// Space rules whose rejection is the space limit of a text block.
const _spaceRules = {
  EditorRule.blockOverlap,
  EditorRule.groupOverlap,
  EditorRule.pageBounds,
};

class TextHandler extends ChangeNotifier {
  TextHandler({
    required this.paper,
    required this.preferences,
    this.blocks = const TextBlocks(),
    String Function()? newId,
  }) : newId = newId ?? _randomId;

  final PaperHandler paper;
  final Preferences preferences;
  final TextBlocks blocks;
  final String Function() newId;

  /// The engine that measures and lays out text: the paper text style.
  late final engine = QuillTextEngine(style: paper.textStyle);

  /// The id of the text item in the live editor, or null.
  String? get editing => _binding?.itemId;

  GuardedQuillController? _controller;
  TextItemBinding? _binding;
  final editorKey = GlobalKey<QuillEditorState>();
  final focus = FocusNode(debugLabel: 'text block');
  final scroll = ScrollController();

  /// The live editor controller while a block is open.
  GuardedQuillController? get controller => _controller;

  /// True after a blocked input until the next accepted change, OK or the
  /// end of editing: the block border is red.
  bool limited = false;

  /// True while the space limit message covers the block.
  bool messageShown = false;

  /// One tick per blocked input; the editor shakes the block on a new tick
  /// unless a shake is running or reduced motion is on.
  final shakes = ValueNotifier(0);

  // Opening and closing ---------------------------------------------------

  /// A click or tap on the page at [screen] that no editor took. In Type
  /// mode it ends the open block, then opens the text block there or starts
  /// a new block on empty paper. [global] places the cursor in a block.
  void tapAt(Offset screen, {Offset? global}) {
    final view = paper.view.value;
    if (view == null || paper.tool != SelectionTool.type) return;
    if (paper.document is! PaperDocument) return;
    end();
    final p = view.toPage(screen);
    final point = InkVec(p.dx, p.dy);
    final layout = paper.layout;
    if (layout == null) return;
    final id = blocks.textAt(layout, point);
    if (id != null) {
      _open(id, null);
      if (global != null) _placeCursor(global);
      return;
    }
    if (!blocks.isEmptyPaper(layout, point)) return;
    final created = newId();
    final place = blocks.place(
      paper.session.rules,
      paper.document,
      id: created,
      x: p.dx,
      y: p.dy,
      width: paper.settings.textBlockWidth,
      minWidth: paper.settings.minTextBlockWidth,
      lineHeight: (width) => engine.measureHeight(const [], width),
    );
    if (place != null) _open(created, place);
  }

  void _open(String id, TextBlockPlace? place) {
    final binding = _binding = TextItemBinding(
      paper.session,
      id,
      engine,
      place: place,
    );
    _controller = GuardedQuillController(
      engine: engine,
      binding: _PaperBinding(binding, this),
      onRejected: _rejected,
    )..composingRange = quillComposingRange(editorKey);
    final end = binding.spans.fold<int>(
      0,
      (n, s) => n + (s['text'] as String).length,
    );
    _controller!.updateSelection(
      TextSelection.collapsed(offset: end),
      ChangeSource.local,
    );
    focus.addListener(_focusChanged);
    paper.editingText = id;
    notifyListeners();
    _afterFrame(focus.requestFocus);
  }

  void _placeCursor(Offset global) => _afterFrame(() {
    final c = _controller;
    final offset = quillOffsetAt(editorKey, global);
    if (c == null || offset == null) return;
    c.updateSelection(
      TextSelection.collapsed(offset: offset),
      ChangeSource.local,
    );
  });

  /// Closes the open block. An open IME composition is committed first.
  void end() {
    final c = _controller;
    if (c == null) return;
    c.commitComposition();
    focus.removeListener(_focusChanged);
    _controller = null;
    _binding = null;
    limited = false;
    messageShown = false;
    paper.editingText = null;
    notifyListeners();
    // The editor leaves the tree in the next frame; then the controller
    // can go.
    _afterFrame(c.dispose);
  }

  // Quill does not report a composition that ends without a text change.
  void _focusChanged() {
    if (!focus.hasFocus) _controller?.commitComposition();
  }

  // Geometry --------------------------------------------------------------

  /// The page rectangle of the open block: the stored item, or the place
  /// and one empty line for a new block.
  Rect? get block {
    final binding = _binding;
    if (binding == null) return null;
    final item = binding.stored;
    if (item != null) {
      final b = item.bounds!;
      return Rect.fromLTWH(
        b.x.toDouble(),
        b.y.toDouble(),
        b.width.toDouble(),
        b.height.toDouble(),
      );
    }
    final place = binding.place!;
    return Rect.fromLTWH(
      place.x.toDouble(),
      place.y.toDouble(),
      place.width.toDouble(),
      engine.measureHeight(const [], place.width).toDouble(),
    );
  }

  // Space limit -----------------------------------------------------------

  void _rejected(TextCommit rejection) {
    final error = rejection.error;
    if (error is! EditorRuleError || !_spaceRules.contains(error.code)) {
      return;
    }
    limited = true;
    messageShown = preferences.spaceLimitMessage;
    shakes.value++;
    notifyListeners();
  }

  /// OK: the message goes and the text shows again.
  void ok() {
    messageShown = false;
    notifyListeners();
    focus.requestFocus();
  }

  /// Don't show this message again: later blocked input keeps the red
  /// border and the shake without the message.
  void dontShowAgain() {
    preferences.hideSpaceLimitMessage();
    ok();
  }

  void _accepted() {
    if (limited || messageShown) {
      limited = false;
      messageShown = false;
    }
    paper.edited();
    notifyListeners();
  }

  // Text tools ------------------------------------------------------------

  /// The formatting of the selection, in the stored span fields.
  Map<String, Object?> get format =>
      _controller?.selectionFormat ?? const <String, Object?>{};

  /// Applies [format] to the selection only, as one formatting change that
  /// the type C guard checks (a larger size may not fit).
  void apply(TextFormat format) {
    final c = _controller;
    if (c == null) return;
    c.formatSelectionWith(format);
    notifyListeners();
    focus.requestFocus();
  }

  void toggle(String field) {
    final on = format[field] == true;
    apply(switch (field) {
      'bold' => TextFormat.bold(!on),
      'italic' => TextFormat.italic(!on),
      _ => TextFormat.strikethrough(!on),
    });
  }

  /// A size of the Size tool; the base size removes the stored size.
  void size(num value) =>
      apply(TextFormat.size(value == paper.textStyle.fontSize ? null : value));

  /// A color of the Color tool as #RRGGBBAA; null is Automatic.
  void color(String? value) => apply(TextFormat.color(value));

  void _afterFrame(VoidCallback callback) {
    SchedulerBinding.instance.addPostFrameCallback((_) => callback());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    final c = _controller;
    _controller = null;
    focus.removeListener(_focusChanged);
    c?.dispose();
    focus.dispose();
    scroll.dispose();
    shakes.dispose();
    super.dispose();
  }
}

/// The text binding of the open block. An accepted change, Undo and Redo
/// reach the paper (autosave, page length, repaint).
final class _PaperBinding implements TextBinding {
  _PaperBinding(this._inner, this._handler);
  final TextItemBinding _inner;
  final TextHandler _handler;

  @override
  TextSpans get spans => _inner.spans;

  @override
  TextCommit commit(TextChange change) {
    final result = _inner.commit(change);
    if (result.accepted) _handler._accepted();
    return result;
  }

  @override
  bool undo() {
    final moved = _inner.undo();
    if (moved) _handler._accepted();
    return moved;
  }

  @override
  bool redo() {
    final moved = _inner.redo();
    if (moved) _handler._accepted();
    return moved;
  }

  @override
  bool get canUndo => _inner.canUndo;

  @override
  bool get canRedo => _inner.canRedo;
}

final _random = math.Random.secure();

String _randomId() =>
    'text-${List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join()}';
