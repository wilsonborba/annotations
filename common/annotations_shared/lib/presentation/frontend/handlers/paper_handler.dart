/// The flow of one open note on the paper canvas (annotations#26).
///
/// The canvas widgets call this handler; the handler calls the domain: the
/// editor session and its history, the paper page, the object selector and
/// the autosave service. The handler keeps the view (zoom and position),
/// which is never stored and never changes a document position (B1.1).
///
/// Hooks for later issues: [apply] runs every edit of a tool (text #27, pens
/// #28, points #29, erasers #30, selection #32, attachments #34) and saves an
/// accepted result; [select] sets the selection (#32); [activeInk] carries the
/// stroke being drawn (#28, the draw handler); [locked] is read by the view lock
/// (#33).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';

import '../../../core/paper_settings.dart';
import '../../../dal/local/quill_text_engine.dart' show annotationsTextStyle;
import '../../../domain/models/ink.dart';
import '../../../domain/models/local_note.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/ink_outline.dart';
import '../../../domain/services/note_autosave.dart';
import '../../../domain/services/note_history.dart';
import '../../../domain/services/object_selection.dart';
import '../../../domain/services/paper_page.dart';

/// What the notice after Undo or Redo says: the steps back and forward.
@immutable
final class HistoryNotice {
  const HistoryNotice({
    required this.undo,
    required this.back,
    required this.forward,
  });
  final bool undo;
  final int back, forward;
}

/// What the viewport shows: [scroll] is the page point at the top left of
/// the viewport, [zoom] the screen pixels per page unit.
@immutable
final class PaperView {
  const PaperView({
    required this.zoom,
    required this.scroll,
    required this.size,
  });

  final double zoom;
  final Offset scroll;

  /// The viewport in screen pixels.
  final Size size;

  Offset toScreen(Offset page) => (page - scroll) * zoom;
  Offset toPage(Offset screen) => screen / zoom + scroll;
  Rect rectToScreen(Rect page) =>
      Rect.fromPoints(toScreen(page.topLeft), toScreen(page.bottomRight));

  /// The page area inside the viewport.
  Rect get visiblePage => Rect.fromLTWH(
    scroll.dx,
    scroll.dy,
    size.width / zoom,
    size.height / zoom,
  );

  @override
  bool operator ==(Object other) =>
      other is PaperView &&
      other.zoom == zoom &&
      other.scroll == scroll &&
      other.size == size;

  @override
  int get hashCode => Object.hash(zoom, scroll, size);
}

class PaperHandler extends ChangeNotifier {
  PaperHandler({
    required this.noteId,
    required NoteDocument document,
    required this.autosave,
    this.title,
    this.settings = const PaperSettings(),
    this.selector = const ObjectSelector(),
    this.textStyle = annotationsTextStyle,
  }) : session = EditorSession.open(document),
       page = PaperPage(settings: settings);

  /// Opens a saved local note.
  factory PaperHandler.open(
    LocalNote note,
    NoteAutosave autosave, {
    PaperSettings settings = const PaperSettings(),
  }) => PaperHandler(
    noteId: note.id,
    document: note.document,
    title: note.title,
    autosave: autosave,
    settings: settings,
  );

  final String noteId;
  final String? title;
  final NoteAutosave autosave;
  final PaperSettings settings;
  final ObjectSelector selector;
  final PaperPage page;
  final EditorSession session;

  /// The paragraph style of text items: the style that the text engine
  /// measures with, so drawn text has the stored block size.
  final TextStyle textStyle;

  /// The view, null until the canvas has its size.
  final view = ValueNotifier<PaperView?>(null);

  /// The unit under a hovering mouse or pen; never set by touch.
  final hover = ValueNotifier<String?>(null);

  /// The selected units. Only the selection border is drawn here; the
  /// gestures come with annotations#32.
  final selection = ValueNotifier(ObjectSelection.empty);

  /// The device of the last pointer on the page. Handles are larger for
  /// touch, and touch has no hover.
  final pointer = ValueNotifier(PointerDeviceKind.mouse);

  /// The outline of the stroke being drawn. Only the active stroke layer
  /// listens to it, so drawing repaints nothing else.
  final activeInk = ValueNotifier<InkOutline?>(null);

  /// A background shown while its control is dragged, not saved yet.
  final preview = ValueNotifier<PaperGuides?>(null);

  /// True while the view lock blocks navigation (annotations#33).
  bool locked = false;

  /// True while a selection gesture holds the page: a touch and hold, a
  /// move or a resize (annotations#32).
  bool holding = false;

  /// Navigation never starts during an active ink stroke (B8).
  bool get navigationBlocked => locked || holding || activeInk.value != null;

  /// The notice after Undo or Redo (B2 G2), cleared after
  /// [PaperSettings.historyNotice].
  final historyNotice = ValueNotifier<HistoryNotice?>(null);
  Timer? _noticeTimer;

  void _notice(bool undo) {
    if (session case final NotesEditor notes) {
      _noticeTimer?.cancel();
      historyNotice.value = HistoryNotice(
        undo: undo,
        back: notes.stepsBack,
        forward: notes.stepsForward,
      );
      _noticeTimer = Timer(settings.historyNotice, () {
        historyNotice.value = null;
      });
    }
  }

  SelectionTool _tool = SelectionTool.type;

  /// The editing mode of this editor: Type or Draw (B5). It decides which
  /// objects a pointer reaches. Local state of this editor, never note
  /// data: each Instant participant keeps their own mode. Editing starts in
  /// Type mode; the draw handler switches it.
  SelectionTool get tool => _tool;
  set tool(SelectionTool value) {
    if (value == _tool) return;
    _tool = value;
    hover.value = null;
    notifyListeners();
  }

  ValueListenable<SaveState> get saveState => autosave.state;

  NoteDocument get document => session.document;

  PaperDocument? get _paper =>
      document is PaperDocument ? document as PaperDocument : null;

  /// The stored page width, never the screen width.
  double get pageWidth => _paper?.page.width.toDouble() ?? 0;

  double? _height;
  DocumentLayout? _layout;

  /// The page length for the current content (not stored).
  double get pageHeight => _height ??= page.pageHeight(document, pageWidth);

  /// The layout of the current document state, kept for hover.
  DocumentLayout? get layout => _layout ??= DocumentLayout.of(document);

  /// The stored background, or [PaperGuides.blank] for a kind unknown to
  /// this app.
  PaperGuides get storedGuides => page.guidesOf(document) ?? PaperGuides.blank;

  /// The background to draw: the preview while a control is dragged.
  PaperGuides get guides => preview.value ?? storedGuides;

  // Edits ----------------------------------------------------------------

  /// Runs one edit of a tool. An accepted result becomes the document (one
  /// Undo step in Notes) and goes to autosave; a rejected one changes
  /// nothing and keeps its operation in the decision.
  EditDecision apply(HistoryCommand command, EditBuilder edit) {
    final s = session;
    final decision = switch (s) {
      NotesEditor() => s.apply(command, edit),
      InstantEditor() => s.apply(edit),
    };
    if (decision.accepted) _changed();
    return decision;
  }

  /// Notes Undo and Redo (B2 G2); Instant has neither.
  bool get hasHistory => session is NotesEditor;
  bool get canUndo => switch (session) {
    final NotesEditor notes => notes.canUndo,
    _ => false,
  };
  bool get canRedo => switch (session) {
    final NotesEditor notes => notes.canRedo,
    _ => false,
  };

  void undo() {
    if (session case final NotesEditor notes when notes.undo().moved) {
      _changed();
    }
    _notice(true);
  }

  void redo() {
    if (session case final NotesEditor notes when notes.redo().moved) {
      _changed();
    }
    _notice(false);
  }

  /// Keeps an edit that a tool committed to [session] itself: the live text
  /// editor commits through its text binding (annotations#27).
  void edited() => _changed();

  String? _editingText;

  /// The text item open in the live editor. The content layer leaves it
  /// out, so its text is drawn once.
  String? get editingText => _editingText;
  set editingText(String? id) {
    if (id == _editingText) return;
    _editingText = id;
    notifyListeners();
  }

  /// Picks a background. A pattern keeps the spacing and visibility that
  /// the current background has; blank removes them.
  EditDecision pickPattern(PaperPattern pattern) {
    final current = storedGuides;
    return setGuides(
      PaperGuides.pick(
        pattern,
        from: current.pattern == PaperPattern.blank ? null : current,
        settings: settings,
      ),
    );
  }

  /// Shows [guides] without saving, while a control is dragged.
  void previewGuides(PaperGuides guides) => preview.value = guides;

  /// Saves the background [guides] as one page change.
  EditDecision setGuides(PaperGuides guides) {
    preview.value = null;
    if (guides == storedGuides) {
      notifyListeners();
      return session.rules.check(document);
    }
    final decision = page.setGuides(session, guides);
    if (decision.accepted) _changed();
    return decision;
  }

  /// Sets the selection (annotations#32 calls it from its gestures).
  void select(ObjectSelection value) =>
      selection.value = selector.prune(document, value);

  void _changed() {
    _height = null;
    _layout = null;
    selection.value = selector.prune(document, selection.value);
    if (hover.value != null && layout?.unitOf(hover.value!) == null) {
      hover.value = null;
    }
    autosave.edited(
      LocalNoteDraft(
        id: noteId,
        schema: document.schema,
        document: document,
        title: title,
      ),
    );
    final v = view.value;
    if (v != null) view.value = _clamped(v.scroll, v.zoom, v.size);
    notifyListeners();
  }

  /// Saves again after a failure.
  Future<void> retrySave() => autosave.retry();

  /// Saves the pending edit before the note closes.
  Future<void> close() => autosave.flush();

  // View -----------------------------------------------------------------

  /// The zoom that shows the whole page width, at most 1.
  double fitZoom(Size size) =>
      ((size.width - 2 * settings.deskMargin - _insets.horizontal) /
              math.max(pageWidth, 1))
          .clamp(settings.minZoom, 1.0);

  /// The view for a viewport of [size]. The first size shows the top of the
  /// page at the fit zoom. A later size (window resize, rotation) keeps the
  /// zoom and the page point at the center (B8). Content never moves.
  /// Screen space that a docked toolbar takes at the edges (annotations#31).
  /// The page keeps clear of it, so every part of the page stays reachable.
  EdgeInsets get toolbarInsets => _insets;
  EdgeInsets _insets = EdgeInsets.zero;
  set toolbarInsets(EdgeInsets value) {
    if (value == _insets) return;
    final before = _insets;
    _insets = value;
    final v = view.value;
    if (v == null) return;
    // The page moves by the room the toolbar takes or gives back.
    final shift = Offset(value.left - before.left, value.top - before.top);
    view.value = _clamped(v.scroll - shift / v.zoom, v.zoom, v.size);
  }

  PaperView viewFor(Size size) {
    final v = view.value;
    if (v == null) {
      final zoom = fitZoom(size);
      return _clamped(
        Offset(0, -(settings.deskMargin + _insets.top) / zoom),
        zoom,
        size,
      );
    }
    if (v.size == size) return v;
    final center = v.scroll + Offset(v.size.width, v.size.height) / 2 / v.zoom;
    return _clamped(
      center - Offset(size.width, size.height) / 2 / v.zoom,
      v.zoom,
      size,
    );
  }

  /// Gives the view its viewport (see [viewFor]).
  void layoutView(Size size) => view.value = viewFor(size);

  /// Sets the zoom; the page point under [focal] (screen) stays in place.
  void zoomTo(double zoom, {Offset? focal}) {
    final v = view.value;
    if (v == null || navigationBlocked) return;
    final z = zoom.clamp(settings.minZoom, settings.maxZoom);
    final f = focal ?? Offset(v.size.width, v.size.height) / 2;
    final point = v.toPage(f);
    view.value = _clamped(point - f / z, z, v.size);
  }

  void zoomBy(double factor, {Offset? focal}) {
    final v = view.value;
    if (v != null) zoomTo(v.zoom * factor, focal: focal);
  }

  void zoomIn() => zoomBy(settings.zoomStep);
  void zoomOut() => zoomBy(1 / settings.zoomStep);

  bool get canZoomIn => (view.value?.zoom ?? 0) < settings.maxZoom - 1e-9;
  bool get canZoomOut => (view.value?.zoom ?? 0) > settings.minZoom + 1e-9;

  /// Moves the view by [delta] screen pixels (positive moves the page up and
  /// left, as a scroll does). Returns false at the page edge.
  bool scrollBy(Offset delta) {
    final v = view.value;
    if (v == null || navigationBlocked) return false;
    final next = _clamped(v.scroll + delta / v.zoom, v.zoom, v.size);
    if (next == v) return false;
    view.value = next;
    return true;
  }

  PaperView _clamped(Offset scroll, double zoom, Size size) {
    final d = settings.deskMargin;
    final left = (d + _insets.left) / zoom, right = (d + _insets.right) / zoom;
    final top = (d + _insets.top) / zoom, bottom = (d + _insets.bottom) / zoom;
    final vw = size.width / zoom, vh = size.height / zoom;
    final w = pageWidth, h = pageHeight;
    final double x = w + left + right <= vw
        ? -(left + (vw - left - right - w) / 2)
        : scroll.dx.clamp(-left, w + right - vw);
    final double y = scroll.dy.clamp(-top, math.max(-top, h + bottom - vh));
    return PaperView(zoom: zoom, scroll: Offset(x, y), size: size);
  }

  // Pointer --------------------------------------------------------------

  /// A hovering pointer at [screen]. Touch never hovers.
  void hoverAt(Offset screen, PointerDeviceKind kind) {
    pointer.value = kind;
    final v = view.value;
    final l = layout;
    if (v == null || l == null || kind == PointerDeviceKind.touch) {
      hover.value = null;
      return;
    }
    final p = v.toPage(screen);
    hover.value = selector.hitIn(l, InkVec(p.dx, p.dy), tool);
  }

  void endHover() => hover.value = null;

  /// Records the device of a pointer that touches the page.
  void pointerDown(PointerDeviceKind kind) {
    pointer.value = kind;
    if (kind == PointerDeviceKind.touch) hover.value = null;
  }

  @override
  void dispose() {
    view.dispose();
    hover.dispose();
    selection.dispose();
    pointer.dispose();
    activeInk.dispose();
    preview.dispose();
    _noticeTimer?.cancel();
    historyNotice.dispose();
    super.dispose();
  }
}
