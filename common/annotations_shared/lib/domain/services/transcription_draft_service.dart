import 'dart:convert';
import 'dart:io';

import '../models/local_note.dart';
import '../models/note_document.dart';
import 'local_note_store.dart';

enum TranscriptionPassageKind { text, inkFallback, table, image, card }

final class TranscriptionPassage {
  final String partId;
  final List<String> sourceItemIds;
  final String sourceHash;
  final double y;
  final double x;
  final TranscriptionPassageKind kind;
  final String text;
  final bool uncertain;
  final bool keepAsInk;
  final bool userCorrected;
  final bool feedbackAccepted;
  final Map<String, Object?>? preservedData;

  const TranscriptionPassage({
    required this.partId,
    this.sourceItemIds = const [],
    required this.sourceHash,
    required this.y,
    required this.x,
    required this.kind,
    required this.text,
    this.uncertain = false,
    this.keepAsInk = false,
    this.userCorrected = false,
    this.feedbackAccepted = false,
    this.preservedData,
  });

  TranscriptionPassage copyWith({
    String? sourceHash,
    List<String>? sourceItemIds,
    String? text,
    bool? uncertain,
    bool? keepAsInk,
    bool? userCorrected,
    bool? feedbackAccepted,
  }) => TranscriptionPassage(
    partId: partId,
    sourceItemIds: sourceItemIds ?? this.sourceItemIds,
    sourceHash: sourceHash ?? this.sourceHash,
    y: y,
    x: x,
    kind: kind,
    text: text ?? this.text,
    uncertain: uncertain ?? this.uncertain,
    keepAsInk: keepAsInk ?? this.keepAsInk,
    userCorrected: userCorrected ?? this.userCorrected,
    feedbackAccepted: feedbackAccepted ?? this.feedbackAccepted,
    preservedData: preservedData,
  );

  Map<String, Object?> toJson() => {
    'part_id': partId,
    if (sourceItemIds.isNotEmpty) 'source_item_ids': sourceItemIds,
    'source_hash': sourceHash,
    'y': y,
    'x': x,
    'kind': kind.name,
    'text': text,
    'uncertain': uncertain,
    'keep_as_ink': keepAsInk,
    'user_corrected': userCorrected,
    'feedback_accepted': feedbackAccepted,
    if (preservedData != null) 'preserved_data': preservedData,
  };

  factory TranscriptionPassage.fromJson(Map<String, dynamic> j) =>
      TranscriptionPassage(
        partId: '${j['part_id']}',
        sourceItemIds: ((j['source_item_ids'] as List?) ?? [])
            .whereType<String>()
            .toList(growable: false),
        sourceHash: '${j['source_hash'] ?? ''}',
        y: (j['y'] as num?)?.toDouble() ?? 0,
        x: (j['x'] as num?)?.toDouble() ?? 0,
        kind: TranscriptionPassageKind.values.byName('${j['kind'] ?? 'text'}'),
        text: '${j['text'] ?? ''}',
        uncertain: (j['uncertain'] as bool?) ?? false,
        keepAsInk: (j['keep_as_ink'] as bool?) ?? false,
        userCorrected: (j['user_corrected'] as bool?) ?? false,
        feedbackAccepted: (j['feedback_accepted'] as bool?) ?? false,
        preservedData: j['preserved_data'] is Map
            ? Map<String, Object?>.from(j['preserved_data'] as Map)
            : null,
      );
}

final class TranscriptionDraft {
  final String noteId;

  /// Null only for drafts written before owner-bound transcription was added.
  final String? accountId;
  final String? runId;
  final String? downloadId;
  final String? modelVersion;
  final String? platform;
  final List<String> selectedSourceItemIds;
  final Map<String, Object?>? selectedInkDocument;
  final int? schemaVersion;
  final String? language;

  /// The source identity on which the saved recognition was based. This remains
  /// unchanged when the Original changes; a newer identity is kept separately
  /// until the owner explicitly applies an update.
  final int sourceRevision;
  final int? currentSourceRevision;
  final String? baseSourceRevisionId;
  final String? currentSourceRevisionId;
  final String? baseSourceHash;
  final String? currentSourceHash;
  final bool needsReview;
  final List<TranscriptionPassage> passages;
  final List<Map<String, Object?>> pendingFeedbackEvents;

  const TranscriptionDraft({
    required this.noteId,
    this.accountId,
    this.runId,
    this.downloadId,
    this.modelVersion,
    this.platform,
    this.selectedSourceItemIds = const [],
    this.selectedInkDocument,
    this.schemaVersion,
    this.language,
    required this.sourceRevision,
    this.currentSourceRevision,
    this.baseSourceRevisionId,
    this.currentSourceRevisionId,
    this.baseSourceHash,
    this.currentSourceHash,
    this.needsReview = false,
    required this.passages,
    this.pendingFeedbackEvents = const [],
  });

  TranscriptionDraft copyWith({
    String? accountId,
    String? runId,
    String? downloadId,
    String? modelVersion,
    String? platform,
    List<String>? selectedSourceItemIds,
    Map<String, Object?>? selectedInkDocument,
    int? schemaVersion,
    String? language,
    int? sourceRevision,
    int? currentSourceRevision,
    String? baseSourceRevisionId,
    String? currentSourceRevisionId,
    String? baseSourceHash,
    String? currentSourceHash,
    bool clearCurrentSource = false,
    bool? needsReview,
    List<TranscriptionPassage>? passages,
    List<Map<String, Object?>>? pendingFeedbackEvents,
  }) => TranscriptionDraft(
    noteId: noteId,
    accountId: accountId ?? this.accountId,
    runId: runId ?? this.runId,
    downloadId: downloadId ?? this.downloadId,
    modelVersion: modelVersion ?? this.modelVersion,
    platform: platform ?? this.platform,
    selectedSourceItemIds: selectedSourceItemIds ?? this.selectedSourceItemIds,
    selectedInkDocument: selectedInkDocument ?? this.selectedInkDocument,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    language: language ?? this.language,
    sourceRevision: sourceRevision ?? this.sourceRevision,
    currentSourceRevision: clearCurrentSource
        ? null
        : currentSourceRevision ?? this.currentSourceRevision,
    baseSourceRevisionId: baseSourceRevisionId ?? this.baseSourceRevisionId,
    currentSourceRevisionId: clearCurrentSource
        ? null
        : currentSourceRevisionId ?? this.currentSourceRevisionId,
    baseSourceHash: baseSourceHash ?? this.baseSourceHash,
    currentSourceHash: clearCurrentSource
        ? null
        : currentSourceHash ?? this.currentSourceHash,
    needsReview: needsReview ?? this.needsReview,
    passages: passages ?? this.passages,
    pendingFeedbackEvents: pendingFeedbackEvents ?? this.pendingFeedbackEvents,
  );

  Map<String, Object?> toJson() => {
    'note_id': noteId,
    if (accountId != null) 'account_id': accountId,
    if (runId != null) 'run_id': runId,
    if (downloadId != null) 'download_id': downloadId,
    if (modelVersion != null) 'model_version': modelVersion,
    if (platform != null) 'platform': platform,
    if (selectedSourceItemIds.isNotEmpty)
      'selected_source_item_ids': selectedSourceItemIds,
    if (selectedInkDocument != null)
      'selected_ink_document': selectedInkDocument,
    if (schemaVersion != null) 'schema_version': schemaVersion,
    if (language != null) 'language': language,
    'source_revision': sourceRevision,
    if (currentSourceRevision != null)
      'current_source_revision': currentSourceRevision,
    if (baseSourceRevisionId != null)
      'base_source_revision_id': baseSourceRevisionId,
    if (currentSourceRevisionId != null)
      'current_source_revision_id': currentSourceRevisionId,
    if (baseSourceHash != null) 'base_source_hash': baseSourceHash,
    if (currentSourceHash != null) 'current_source_hash': currentSourceHash,
    'needs_review': needsReview,
    'passages': [for (final p in passages) p.toJson()],
    'pending_feedback_events': pendingFeedbackEvents,
  };

  factory TranscriptionDraft.fromJson(Map<String, dynamic> j) =>
      TranscriptionDraft(
        noteId: '${j['note_id']}',
        accountId: j['account_id'] as String?,
        runId: j['run_id'] as String?,
        downloadId: j['download_id'] as String?,
        modelVersion: j['model_version'] as String?,
        platform: j['platform'] as String?,
        selectedSourceItemIds: ((j['selected_source_item_ids'] as List?) ?? [])
            .whereType<String>()
            .toList(growable: false),
        selectedInkDocument: j['selected_ink_document'] is Map
            ? Map<String, Object?>.from(j['selected_ink_document'] as Map)
            : null,
        schemaVersion: (j['schema_version'] as num?)?.toInt(),
        language: j['language'] as String?,
        sourceRevision: (j['source_revision'] as num?)?.toInt() ?? 1,
        currentSourceRevision: (j['current_source_revision'] as num?)?.toInt(),
        baseSourceRevisionId: j['base_source_revision_id'] as String?,
        currentSourceRevisionId: j['current_source_revision_id'] as String?,
        baseSourceHash: j['base_source_hash'] as String?,
        currentSourceHash: j['current_source_hash'] as String?,
        needsReview: (j['needs_review'] as bool?) ?? false,
        passages: ((j['passages'] as List?) ?? const [])
            .map(
              (e) => TranscriptionPassage.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(),
        pendingFeedbackEvents:
            ((j['pending_feedback_events'] as List?) ?? const [])
                .whereType<Map>()
                .map((event) => Map<String, Object?>.from(event))
                .toList(growable: false),
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

  bool get hasDurableStorage => persistenceFile != null;

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
    final temporary = File('${f.path}.writing');
    try {
      temporary.writeAsStringSync(
        jsonEncode({
          for (final e in _savedDrafts.entries) e.key: e.value.toJson(),
        }),
        flush: true,
      );
      temporary.renameSync(f.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  TranscriptionDraft? reopenDraft(String noteId, {String? accountId}) {
    final draft = _savedDrafts[_draftKey(noteId, accountId)];
    if (accountId != null && draft?.accountId != accountId) return null;
    return draft;
  }

  String _draftKey(String noteId, String? accountId) =>
      accountId == null ? noteId : '$accountId::$noteId';

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
    String? accountId,
    String? runId,
    String? downloadId,
    String? modelVersion,
    String? platform,
    List<String> selectedSourceItemIds = const [],
    Map<String, Object?>? selectedInkDocument,
    int? schemaVersion,
    String? language,
    String? sourceRevisionId,
    String? sourceHash,
  }) {
    final key = _draftKey(noteId, accountId);
    final sorted = [...passages]
      ..sort((a, b) {
        final c = a.y.compareTo(b.y);
        return c != 0 ? c : a.x.compareTo(b.x);
      });
    final draft = TranscriptionDraft(
      noteId: noteId,
      accountId: accountId,
      runId: runId,
      downloadId: downloadId,
      modelVersion: modelVersion,
      platform: platform,
      selectedSourceItemIds: List.unmodifiable(selectedSourceItemIds),
      selectedInkDocument: selectedInkDocument,
      schemaVersion: schemaVersion,
      language: language,
      sourceRevision: sourceRevision,
      baseSourceHash: sourceHash,
      baseSourceRevisionId: sourceRevisionId,
      passages: sorted,
    );
    _savedDrafts[key] = draft;
    _saveToDisk();
    return draft;
  }

  /// Saves model output onto the registered draft without replacing its saved
  /// owner, run, source, or changed-source review metadata.
  TranscriptionDraft saveRecognizedPassages(
    String noteId,
    List<TranscriptionPassage> passages, {
    String? accountId,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null || draft.runId == null) {
      throw StateError('Missing registered draft for $noteId');
    }
    final sorted = [...passages]
      ..sort((a, b) {
        final vertical = a.y.compareTo(b.y);
        return vertical != 0 ? vertical : a.x.compareTo(b.x);
      });
    final updated = draft.copyWith(passages: sorted);
    _commitDraft(key, updated);
    return updated;
  }

  /// Reorders passages before acceptance.
  TranscriptionDraft reorderPassage(
    String noteId,
    int oldIndex,
    int newIndex, {
    String? accountId,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final list = [...draft.passages];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    final updated = draft.copyWith(passages: list);
    _savedDrafts[key] = updated;
    _saveToDisk();
    return updated;
  }

  /// Applies an owner correction to [partId], surviving future changed-part updates.
  TranscriptionDraft applyUserCorrection(
    String noteId,
    String partId, {
    String? correctedText,
    bool? keepAsInk,
    String? accountId,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final updatedPassages = [
      for (final p in draft.passages)
        if (p.partId == partId)
          p.copyWith(
            text: correctedText ?? p.text,
            keepAsInk: keepAsInk ?? p.keepAsInk,
            uncertain: false,
            userCorrected: true,
            feedbackAccepted: false,
          )
        else
          p,
    ];
    final updated = draft.copyWith(passages: updatedPassages);
    _savedDrafts[key] = updated;
    _saveToDisk();
    return updated;
  }

  /// Persists a correction or Keep Ink decision together with the exact frozen
  /// feedback event that reports it. A failure to replace the durable draft
  /// restores the in-memory value too, so neither half can appear committed.
  TranscriptionDraft applyCorrectionWithPendingFeedback(
    String noteId,
    String partId, {
    required Map<String, Object?> event,
    required String accountId,
    String? correctedText,
    bool? keepAsInk,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null || draft.runId == null) {
      throw StateError('Missing registered draft for $noteId');
    }
    final matching = draft.passages.where(
      (passage) => passage.partId == partId,
    );
    if (matching.length != 1) throw StateError('Missing passage $partId');
    final frozen = _freezeFeedbackEvent(event);
    if (frozen['segment_id'] != partId ||
        frozen['stage'] is! String ||
        frozen['correction'] is! String ||
        (correctedText != null && frozen['correction'] != correctedText) ||
        (keepAsInk == true && frozen['correction'] != '')) {
      throw ArgumentError('Feedback does not describe the selected passage.');
    }
    final eventId = frozen['event_id']! as String;
    final duplicate = draft.pendingFeedbackEvents.where(
      (item) => item['event_id'] == eventId,
    );
    if (duplicate.isNotEmpty) {
      if (jsonEncode(duplicate.single) != jsonEncode(frozen)) {
        throw StateError('A feedback event id cannot change its body.');
      }
      return draft;
    }
    final updated = draft.copyWith(
      passages: [
        for (final passage in draft.passages)
          if (passage.partId == partId)
            passage.copyWith(
              text: correctedText ?? passage.text,
              keepAsInk: keepAsInk ?? passage.keepAsInk,
              uncertain: false,
              userCorrected: true,
              feedbackAccepted: false,
            )
          else
            passage,
      ],
      pendingFeedbackEvents: [...draft.pendingFeedbackEvents, frozen],
    );
    _commitDraft(key, updated);
    return updated;
  }

  Map<String, Object?> _freezeFeedbackEvent(Map<String, Object?> event) {
    final frozen = Map<String, Object?>.from(
      jsonDecode(jsonEncode(event)) as Map,
    );
    final eventId = frozen['event_id'];
    if (eventId is! String || eventId.isEmpty) {
      throw ArgumentError('Feedback event id is required.');
    }
    return frozen;
  }

  void _commitDraft(String key, TranscriptionDraft updated) {
    final previous = _savedDrafts[key];
    _savedDrafts[key] = updated;
    try {
      _saveToDisk();
    } catch (_) {
      if (previous == null) {
        _savedDrafts.remove(key);
      } else {
        _savedDrafts[key] = previous;
      }
      rethrow;
    }
  }

  /// Records a frozen feedback event in the same atomic private draft write as
  /// the correction. It bridges a crash/session change before the network retry
  /// queue receives that event.
  TranscriptionDraft recordPendingFeedback(
    String noteId,
    Map<String, Object?> event, {
    required String accountId,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null || draft.runId == null) {
      throw StateError('Missing registered draft for $noteId');
    }
    final frozen = _freezeFeedbackEvent(event);
    final eventId = frozen['event_id']! as String;
    final existing = draft.pendingFeedbackEvents.where(
      (item) => item['event_id'] == eventId,
    );
    if (existing.isNotEmpty) {
      if (jsonEncode(existing.single) != jsonEncode(frozen)) {
        throw StateError('A feedback event id cannot change its body.');
      }
      return draft;
    }
    final updated = draft.copyWith(
      pendingFeedbackEvents: [...draft.pendingFeedbackEvents, frozen],
    );
    _commitDraft(key, updated);
    return updated;
  }

  TranscriptionDraft acknowledgePendingFeedback(
    String noteId,
    String eventId, {
    required String accountId,
    required String expectedRunId,
    required String? expectedSourceRevisionId,
    required String? expectedSourceHash,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null) throw StateError('Missing draft for $noteId');
    if (draft.runId != expectedRunId ||
        draft.baseSourceRevisionId != expectedSourceRevisionId ||
        draft.baseSourceHash != expectedSourceHash) {
      return draft;
    }
    final matchingEvents = draft.pendingFeedbackEvents.where(
      (event) => event['event_id'] == eventId,
    );
    final event = matchingEvents.isEmpty ? null : matchingEvents.single;
    final partId = event?['segment_id'];
    final correction = event?['correction'];
    final acceptedStage = event?['stage'] == 'accepted';
    final sourceIds = event?['source_item_ids'];
    final passages = [
      for (final passage in draft.passages)
        if (acceptedStage &&
            !draft.needsReview &&
            partId == passage.partId &&
            passage.userCorrected &&
            sourceIds is List &&
            sourceIds.every((id) => id is String) &&
            jsonEncode(sourceIds) ==
                jsonEncode(
                  passage.sourceItemIds.isNotEmpty
                      ? passage.sourceItemIds
                      : [passage.partId],
                ) &&
            (passage.keepAsInk ? correction == '' : correction == passage.text))
          passage.copyWith(feedbackAccepted: true)
        else
          passage,
    ];
    final updated = draft.copyWith(
      passages: passages,
      pendingFeedbackEvents: draft.pendingFeedbackEvents
          .where((event) => event['event_id'] != eventId)
          .toList(growable: false),
    );
    _commitDraft(key, updated);
    return updated;
  }

  List<
    ({
      String noteId,
      String runId,
      String? sourceRevisionId,
      String? sourceHash,
      Map<String, Object?> event,
    })
  >
  pendingFeedbackForOwner(String accountId) => [
    for (final draft in _savedDrafts.values)
      if (draft.accountId == accountId && draft.runId != null)
        for (final event in draft.pendingFeedbackEvents)
          (
            noteId: draft.noteId,
            runId: draft.runId!,
            sourceRevisionId: draft.baseSourceRevisionId,
            sourceHash: draft.baseSourceHash,
            event: event,
          ),
  ];

  /// Marks the draft for review when the source Original note changes.
  TranscriptionDraft markSourceChanged(
    String noteId, {
    int? newSourceRevision,
    String? newSourceHash,
    String? newSourceRevisionId,
    String? accountId,
  }) {
    if (newSourceRevision == null &&
        newSourceHash == null &&
        newSourceRevisionId == null) {
      throw ArgumentError('A current source revision or hash is required.');
    }
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final updated = draft.copyWith(
      currentSourceRevision: newSourceRevision,
      currentSourceRevisionId: newSourceRevisionId,
      currentSourceHash: newSourceHash,
      needsReview: true,
    );
    _savedDrafts[key] = updated;
    _saveToDisk();
    return updated;
  }

  /// Returns only the part IDs whose source hash changed since the draft was saved.
  List<String> changedPartIds(
    String noteId,
    List<Map<String, dynamic>> currentItems, {
    String? accountId,
  }) {
    final draft = _savedDrafts[_draftKey(noteId, accountId)];
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
    int? resultBaseRevision,
    String? resultBaseHash,
    String? resultBaseRevisionId,
    required Map<String, TranscriptionPassage> updatedResultsByPartId,
    String? accountId,
  }) {
    final key = _draftKey(noteId, accountId);
    final draft = _savedDrafts[key];
    if (draft == null) throw StateError('Missing draft for $noteId');
    final expectedRevision =
        draft.currentSourceRevision ?? draft.sourceRevision;
    final expectedRevisionId =
        draft.currentSourceRevisionId ?? draft.baseSourceRevisionId;
    final suppliedIdentityCount = [
      resultBaseRevision != null,
      resultBaseHash != null,
      resultBaseRevisionId != null,
    ].where((present) => present).length;
    if (suppliedIdentityCount != 1 ||
        (resultBaseRevision != null &&
            resultBaseRevision != expectedRevision) ||
        (resultBaseHash != null &&
            resultBaseHash !=
                (draft.currentSourceHash ?? draft.baseSourceHash)) ||
        (resultBaseRevisionId != null &&
            resultBaseRevisionId != expectedRevisionId)) {
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

    final updated = draft.copyWith(
      sourceRevision: draft.currentSourceRevision ?? draft.sourceRevision,
      baseSourceRevisionId:
          draft.currentSourceRevisionId ?? draft.baseSourceRevisionId,
      baseSourceHash: draft.currentSourceHash ?? draft.baseSourceHash,
      clearCurrentSource: true,
      needsReview: false,
      passages: merged,
    );
    _savedDrafts[key] = updated;
    _saveToDisk();
    return updated;
  }

  /// Cancelling leaves the Original note untouched and keeps completed draft results.
  TranscriptionDraft? cancel(String noteId, {String? accountId}) =>
      _savedDrafts[_draftKey(noteId, accountId)];

  /// Accepts [noteId]'s draft into a [TypedDocument]. Original strokes are untouched.
  NoteDocument acceptToTyped(String noteId, {String? accountId}) {
    final draft = _savedDrafts[_draftKey(noteId, accountId)];
    if (draft == null) throw StateError('Missing draft for $noteId');
    if (draft.needsReview) {
      throw StateError(
        'The changed source must be reviewed before acceptance.',
      );
    }
    final blocks = <Map<String, Object?>>[
      for (final p in draft.passages)
        if (p.keepAsInk || p.kind == TranscriptionPassageKind.inkFallback)
          _retainedInkBlock(p)
        else if (p.kind == TranscriptionPassageKind.table ||
            p.kind == TranscriptionPassageKind.image ||
            p.kind == TranscriptionPassageKind.card)
          ..._preservedTypedBlocks(p)
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

  Map<String, Object?> _retainedInkBlock(TranscriptionPassage passage) {
    final preserved = passage.preservedData;
    final width = preserved?['width'];
    final height = preserved?['height'];
    final ink = preserved?['ink'];
    if (width is! num ||
        !width.isFinite ||
        width <= 0 ||
        height is! num ||
        !height.isFinite ||
        height <= 0 ||
        ink is! List ||
        ink.isEmpty) {
      throw UnsupportedTranscriptionStructureException(passage.partId);
    }
    for (final item in ink) {
      if (item is! Map) {
        throw UnsupportedTranscriptionStructureException(passage.partId);
      }
      final decoded = DocumentItem.fromJson(
        item,
        family: DocumentFamily.original,
      );
      if (decoded is! StrokeItem && decoded is! ShapeItem) {
        throw UnsupportedTranscriptionStructureException(passage.partId);
      }
    }
    return {
      'id': 'blk_${passage.partId}',
      'kind': 'handwriting',
      'width': width,
      'height': height,
      'ink': ink,
    };
  }

  List<Map<String, Object?>> _preservedTypedBlocks(
    TranscriptionPassage passage,
  ) {
    final raw = passage.preservedData?['typed_blocks'];
    if (raw is! List || raw.isEmpty || raw.any((item) => item is! Map)) {
      throw UnsupportedTranscriptionStructureException(passage.partId);
    }
    final blocks = raw
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList(growable: false);
    const knownTypedKinds = {
      'heading',
      'paragraph',
      'list',
      'table',
      'figure',
      'handwriting',
      'file_card',
      'link_card',
      'website_card',
      'youtube_card',
      'csv_table',
      'pdf_preview',
      'reports_embed',
      'task_card',
      'quiz_card',
    };
    if (blocks.any(
      (block) =>
          block['kind'] is! String ||
          !knownTypedKinds.contains(block['kind']) ||
          block['id'] is! String ||
          (block['id'] as String).isEmpty,
    )) {
      throw UnsupportedTranscriptionStructureException(passage.partId);
    }
    for (final block in blocks) {
      if (DocumentItem.fromJson(block, family: DocumentFamily.typed)
          is OpaqueItem) {
        throw UnsupportedTranscriptionStructureException(passage.partId);
      }
    }
    return blocks;
  }

  /// Accepts [noteId]'s draft and writes the Typed representation into [store]
  /// under [typedNoteId] (default `'${noteId}__typed'`), leaving the Original note
  /// and its strokes untouched in [store].
  Future<LocalNote> acceptToTypedNote(
    String noteId, {
    required LocalNoteStore store,
    String? accountId,
    String? typedNoteId,
    String? title,
  }) async {
    final draft = reopenDraft(noteId, accountId: accountId);
    if (draft == null) throw StateError('Missing draft for $noteId');
    final typedDoc = acceptToTyped(noteId, accountId: accountId);
    final orig = await store.load(noteId);
    if (orig == null ||
        (accountId != null &&
            orig.accountId != null &&
            orig.accountId != accountId)) {
      throw StateError('Original note is unavailable for this owner.');
    }
    if (orig.revision != draft.sourceRevision) {
      throw StateError(
        'The Original changed; review its updated source first.',
      );
    }
    if (draft.baseSourceRevisionId != null &&
        orig.serverOriginalRevisionId != draft.baseSourceRevisionId) {
      throw StateError(
        'The Original changed; review its updated source first.',
      );
    }
    if (draft.accountId != null &&
        orig.accountId != null &&
        orig.accountId != draft.accountId) {
      throw StateError('Original note is unavailable for this owner.');
    }
    final typedId = typedNoteId ?? '${noteId}__typed';
    final existingTyped = await store.load(typedId);
    if (existingTyped != null &&
        existingTyped.transcriptionSourceNoteId != noteId) {
      throw StateError('The Typed note id is already used by another note.');
    }
    return store.save(
      LocalNoteDraft(
        id: typedId,
        schema: typedDoc.schema,
        document: typedDoc,
        title: title ?? orig.title,
        accountId: orig.accountId ?? draft.accountId,
        transcriptionSourceNoteId: noteId,
        transcriptionRunId: draft.runId,
        transcriptionSourceRevisionId:
            draft.baseSourceRevisionId ?? orig.serverOriginalRevisionId,
        transcriptionSourceHash: draft.baseSourceHash,
        transcriptionSourceLocalRevision: orig.revision,
      ),
    );
  }
}

final class UnsupportedTranscriptionStructureException implements Exception {
  const UnsupportedTranscriptionStructureException(this.partId);

  /// The local source item identifier; no source content is included.
  final String partId;
}
