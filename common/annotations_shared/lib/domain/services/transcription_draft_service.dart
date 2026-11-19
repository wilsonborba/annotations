import 'dart:convert';
import 'dart:io';

import '../models/local_note.dart';
import '../models/note_document.dart';
import 'local_note_store.dart';

enum TranscriptionPassageKind { text, inkFallback, table, image, card }

final class TranscriptionPassage {
  final String partId;
  final String sourceHash;
  final double y;
  final double x;
  final TranscriptionPassageKind kind;
  final String text;
  final bool uncertain;
  final bool keepAsInk;
  final bool userCorrected;
  final Map<String, Object?>? preservedData;

  const TranscriptionPassage({
    required this.partId,
    required this.sourceHash,
    required this.y,
    required this.x,
    required this.kind,
    required this.text,
    this.uncertain = false,
    this.keepAsInk = false,
    this.userCorrected = false,
    this.preservedData,
  });

  TranscriptionPassage copyWith({
    String? sourceHash,
    String? text,
    bool? uncertain,
    bool? keepAsInk,
    bool? userCorrected,
  }) => TranscriptionPassage(
    partId: partId,
    sourceHash: sourceHash ?? this.sourceHash,
    y: y,
    x: x,
    kind: kind,
    text: text ?? this.text,
    uncertain: uncertain ?? this.uncertain,
    keepAsInk: keepAsInk ?? this.keepAsInk,
    userCorrected: userCorrected ?? this.userCorrected,
    preservedData: preservedData,
  );

  Map<String, Object?> toJson() => {
    'part_id': partId,
    'source_hash': sourceHash,
    'y': y,
    'x': x,
    'kind': kind.name,
    'text': text,
    'uncertain': uncertain,
    'keep_as_ink': keepAsInk,
    'user_corrected': userCorrected,
    if (preservedData != null) 'preserved_data': preservedData,
  };

  factory TranscriptionPassage.fromJson(Map<String, dynamic> j) =>
      TranscriptionPassage(
        partId: '${j['part_id']}',
        sourceHash: '${j['source_hash'] ?? ''}',
        y: (j['y'] as num?)?.toDouble() ?? 0,
        x: (j['x'] as num?)?.toDouble() ?? 0,
        kind: TranscriptionPassageKind.values.byName('${j['kind'] ?? 'text'}'),
        text: '${j['text'] ?? ''}',
        uncertain: (j['uncertain'] as bool?) ?? false,
        keepAsInk: (j['keep_as_ink'] as bool?) ?? false,
        userCorrected: (j['user_corrected'] as bool?) ?? false,
        preservedData: j['preserved_data'] is Map
            ? Map<String, Object?>.from(j['preserved_data'] as Map)
            : null,
      );
}

final class TranscriptionDraft {
  final String noteId;
  final int sourceRevision;
  final bool needsReview;
  final List<TranscriptionPassage> passages;

  const TranscriptionDraft({
    required this.noteId,
    required this.sourceRevision,
    this.needsReview = false,
    required this.passages,
  });

  TranscriptionDraft copyWith({
    int? sourceRevision,
    bool? needsReview,
    List<TranscriptionPassage>? passages,
  }) => TranscriptionDraft(
    noteId: noteId,
    sourceRevision: sourceRevision ?? this.sourceRevision,
    needsReview: needsReview ?? this.needsReview,
    passages: passages ?? this.passages,
  );

  Map<String, Object?> toJson() => {
    'note_id': noteId,
    'source_revision': sourceRevision,
    'needs_review': needsReview,
    'passages': [for (final p in passages) p.toJson()],
  };

  factory TranscriptionDraft.fromJson(Map<String, dynamic> j) =>
      TranscriptionDraft(
        noteId: '${j['note_id']}',
        sourceRevision: (j['source_revision'] as num?)?.toInt() ?? 1,
        needsReview: (j['needs_review'] as bool?) ?? false,
        passages: ((j['passages'] as List?) ?? const [])
            .map(
              (e) => TranscriptionPassage.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(),
      );
}

/// Manages saved private transcription drafts (persisted across restarts when
/// [persistenceFile] is provided), top-to-bottom / left-to-right typed ordering,
/// user corrections, changed-part updates, and Typed acceptance while keeping
/// Original strokes byte-identical (annotations#46).
class TranscriptionDraftService {
  final File? persistenceFile;
  final Map<String, TranscriptionDraft> _savedDrafts = {};

  TranscriptionDraftService({this.persistenceFile}) {
    _loadFromDisk();
  }

  void _loadFromDisk() {
    final f = persistenceFile;
    if (f == null || !f.existsSync()) return;
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    for (final e in raw.entries) {
      _savedDrafts[e.key] = TranscriptionDraft.fromJson(
        Map<String, dynamic>.from(e.value as Map),
      );
    }
  }

  void _saveToDisk() {
    final f = persistenceFile;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      jsonEncode({
        for (final e in _savedDrafts.entries) e.key: e.value.toJson(),
      }),
    );
  }

  TranscriptionDraft? reopenDraft(String noteId) => _savedDrafts[noteId];

  /// Orders items top to bottom, then left before right. Decorative marks stay
  /// in Original and are excluded from Typed order. Groups stay as one item.
  static List<Map<String, dynamic>> orderForTyped(
    List<Map<String, dynamic>> items, {
    Set<String>? selectedIds,
  }) {
    final filtered = [
      for (final it in items)
        if ((selectedIds == null || selectedIds.contains('${it['id']}')) &&
            it['decorative'] != true)
          it,
    ];
    filtered.sort((a, b) {
      final ay = (a['y'] as num?)?.toDouble() ?? _firstPointY(a);
      final by = (b['y'] as num?)?.toDouble() ?? _firstPointY(b);
      final cmpY = ay.compareTo(by);
      if (cmpY != 0) return cmpY;
      final ax = (a['x'] as num?)?.toDouble() ?? _firstPointX(a);
      final bx = (b['x'] as num?)?.toDouble() ?? _firstPointX(b);
      return ax.compareTo(bx);
    });
    return filtered;
  }

  static double _firstPointY(Map<String, dynamic> it) {
    final pts = it['points'] as List?;
    if (pts != null && pts.isNotEmpty && pts.first is Map) {
      return ((pts.first as Map)['y'] as num?)?.toDouble() ?? 0.0;
    }
    return 0.0;
  }

  static double _firstPointX(Map<String, dynamic> it) {
    final pts = it['points'] as List?;
    if (pts != null && pts.isNotEmpty && pts.first is Map) {
      return ((pts.first as Map)['x'] as num?)?.toDouble() ?? 0.0;
    }
    return 0.0;
  }

  static String hashPart(Map<String, dynamic> item) => jsonEncode(item);

  /// Saves a draft for explicit selected parts or explicit whole-note conversion.
  TranscriptionDraft saveDraft({
    required String noteId,
    required int sourceRevision,
    required List<TranscriptionPassage> passages,
  }) {
    final sorted = [...passages]
      ..sort((a, b) {
        final c = a.y.compareTo(b.y);
        return c != 0 ? c : a.x.compareTo(b.x);
      });
    final draft = TranscriptionDraft(
      noteId: noteId,
      sourceRevision: sourceRevision,
      passages: sorted,
    );
    _savedDrafts[noteId] = draft;
    _saveToDisk();
    return draft;
  }

  /// Reorders passages before acceptance.
  TranscriptionDraft reorderPassage(String noteId, int oldIndex, int newIndex) {
    final draft = _savedDrafts[noteId];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final list = [...draft.passages];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    final updated = draft.copyWith(passages: list);
    _savedDrafts[noteId] = updated;
    _saveToDisk();
    return updated;
  }

  /// Applies an owner correction to [partId], surviving future changed-part updates.
  TranscriptionDraft applyUserCorrection(
    String noteId,
    String partId, {
    String? correctedText,
    bool? keepAsInk,
  }) {
    final draft = _savedDrafts[noteId];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final updatedPassages = [
      for (final p in draft.passages)
        if (p.partId == partId)
          p.copyWith(
            text: correctedText ?? p.text,
            keepAsInk: keepAsInk ?? p.keepAsInk,
            uncertain: false,
            userCorrected: true,
          )
        else
          p,
    ];
    final updated = draft.copyWith(passages: updatedPassages);
    _savedDrafts[noteId] = updated;
    _saveToDisk();
    return updated;
  }

  /// Marks the draft for review when the source Original note changes.
  TranscriptionDraft markSourceChanged(
    String noteId, {
    required int newSourceRevision,
  }) {
    final draft = _savedDrafts[noteId];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final updated = draft.copyWith(
      sourceRevision: newSourceRevision,
      needsReview: true,
    );
    _savedDrafts[noteId] = updated;
    _saveToDisk();
    return updated;
  }

  /// Returns only the part IDs whose source hash changed since the draft was saved.
  List<String> changedPartIds(
    String noteId,
    List<Map<String, dynamic>> currentItems,
  ) {
    final draft = _savedDrafts[noteId];
    if (draft == null) return const [];
    final existingHashes = {
      for (final p in draft.passages) p.partId: p.sourceHash,
    };
    return [
      for (final it in orderForTyped(currentItems))
        if (existingHashes['${it['id']}'] != hashPart(it)) '${it['id']}',
    ];
  }

  /// Applies updated recognition results for changed parts only.
  /// - Rejects results based on an older revision (`resultBaseRevision < draft.sourceRevision`).
  /// - Preserves unchanged parts and ALL `userCorrected` passages.
  TranscriptionDraft applyChangedPartResults({
    required String noteId,
    required int resultBaseRevision,
    required Map<String, TranscriptionPassage> updatedResultsByPartId,
  }) {
    final draft = _savedDrafts[noteId];
    if (draft == null) throw StateError('Missing draft for $noteId');
    if (resultBaseRevision < draft.sourceRevision) {
      // Stale result from an older revision is never applied over newer work.
      return draft;
    }

    final merged = <TranscriptionPassage>[];
    final seen = <String>{};
    for (final existing in draft.passages) {
      seen.add(existing.partId);
      if (existing.userCorrected) {
        merged.add(existing);
      } else if (updatedResultsByPartId.containsKey(existing.partId)) {
        merged.add(updatedResultsByPartId[existing.partId]!);
      } else {
        merged.add(existing);
      }
    }
    for (final entry in updatedResultsByPartId.entries) {
      if (!seen.contains(entry.key)) {
        merged.add(entry.value);
      }
    }

    final updated = draft.copyWith(needsReview: false, passages: merged);
    _savedDrafts[noteId] = updated;
    _saveToDisk();
    return updated;
  }

  /// Cancelling leaves the Original note untouched and keeps completed draft results.
  TranscriptionDraft? cancel(String noteId) => _savedDrafts[noteId];

  /// Accepts [noteId]'s draft into a [TypedDocument]. Original strokes are untouched.
  NoteDocument acceptToTyped(String noteId) {
    final draft = _savedDrafts[noteId];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final blocks = <Map<String, Object?>>[
      for (final p in draft.passages)
        if (p.keepAsInk || p.kind == TranscriptionPassageKind.inkFallback)
          {
            'id': 'blk_${p.partId}',
            'kind': 'paragraph',
            'spans': [
              {'text': '[Handwriting kept: ${p.partId}]'},
            ],
          }
        else if (p.kind == TranscriptionPassageKind.table ||
            p.kind == TranscriptionPassageKind.image ||
            p.kind == TranscriptionPassageKind.card)
          {
            'id': 'blk_${p.partId}',
            'kind': 'paragraph',
            'spans': [
              {'text': p.text},
            ],
            if (p.preservedData != null) ...p.preservedData!,
          }
        else
          {
            'id': 'blk_${p.partId}',
            'kind': 'paragraph',
            'spans': [
              {'text': p.text},
            ],
          },
    ];
    return NoteDocument.fromJson({
      'blocks': blocks,
    }, schema: DocumentSchema(DocumentFamily.typed.schemaName, 1));
  }

  /// Accepts [noteId]'s draft and writes the Typed representation into [store]
  /// under [typedNoteId] (default `'${noteId}__typed'`), leaving the Original note
  /// and its strokes untouched in [store].
  Future<LocalNote> acceptToTypedNote(
    String noteId, {
    required LocalNoteStore store,
    String? typedNoteId,
    String? title,
  }) async {
    final typedDoc = acceptToTyped(noteId);
    final orig = await store.load(noteId);
    return store.save(
      LocalNoteDraft(
        id: typedNoteId ?? '${noteId}__typed',
        schema: typedDoc.schema,
        document: typedDoc,
        title: title ?? orig?.title,
      ),
    );
  }
}
