import 'dart:convert';
import 'dart:math';

import '../models/transcription_session.dart';
import 'model_download_service.dart';
import 'transcription_draft_service.dart';
import 'transcription_run_service.dart';

/// Converts the accepted runtime result document into reviewable passages.
/// The concrete model owns this mapping; the coordinator does not guess a
/// provider-specific word-to-stroke format.
typedef TranscriptionPassageDecoder =
    List<TranscriptionPassage> Function(
      Map<String, Object?> resultDocument,
      List<Map<String, dynamic>> selectedSourceItems,
    );

/// Coordinates an explicitly requested local run with the existing verified
/// download, run, result queue and private draft services. It is not wired into
/// ordinary note saves and does not enable the transcription feature switch.
final class TranscriptionWorkflowService {
  TranscriptionWorkflowService({
    required this.downloads,
    required this.runs,
    required this.drafts,
    required this.sessionProvider,
    required this.decodePassages,
  });

  final ModelDownloadService downloads;
  final TranscriptionRunService runs;
  final TranscriptionDraftService drafts;
  final TranscriptionSessionProvider sessionProvider;
  final TranscriptionPassageDecoder decodePassages;
  final Set<String> _starting = {};

  /// Starts one owner-authenticated run for explicitly selected source items.
  /// The empty draft/run association is persisted after registration and before
  /// local inference, so a later reopen resumes the same run id.
  Future<TranscriptionDraft> startLocal({
    required String noteId,
    required int localSourceRevision,
    String? sourceRevisionId,
    String? sourceHash,
    required List<Map<String, dynamic>> selectedSourceItems,
    required List<String> selectedSourceItemIds,
    required Map<String, Object?> selectedInkDocument,
    required DownloadedModel downloaded,
    required String language,
    required int schemaVersion,
    required TranscriptionRuntime runtime,
    required void Function(String stage) onStage,
  }) async {
    _validateSourceIdentity(sourceRevisionId, sourceHash);
    _validateSelection(selectedSourceItems, selectedSourceItemIds);
    final documentItems = _selectedItems(selectedInkDocument);
    _validateSelectedDocument(
      documentItems,
      selectedSourceItems,
      selectedSourceItemIds,
    );
    if (noteId.trim().isEmpty ||
        localSourceRevision < 1 ||
        selectedInkDocument.isEmpty ||
        schemaVersion < 1 ||
        language.trim().isEmpty) {
      throw ArgumentError('The selected transcription input is incomplete.');
    }
    final session = await _requireSession();
    final key = '${session.accountId}::$noteId';
    if (!_starting.add(key)) {
      throw const TranscriptionWorkflowAlreadyExistsException();
    }
    try {
      if (!drafts.hasDurableStorage ||
          !runs.hasDurableResultQueue ||
          !runs.hasDurableFeedbackQueue) {
        throw const TranscriptionWorkflowUnavailableException();
      }
      if (drafts.reopenDraft(noteId, accountId: session.accountId) != null) {
        throw const TranscriptionWorkflowAlreadyExistsException();
      }
      final grant = downloaded.grant;
      if (!await downloaded.file.exists() ||
          grant.downloadId.trim().isEmpty ||
          grant.modelVersion.trim().isEmpty ||
          grant.platform.trim().isEmpty) {
        throw const ModelArtifactUnavailableException();
      }
      final verifiedModel = await downloads.resume(
        downloadId: grant.downloadId,
        version: grant.modelVersion,
        platform: grant.platform,
        expectedSession: session,
      );
      session.requireCurrent();
      if (verifiedModel.grant.sha256 != grant.sha256 ||
          verifiedModel.grant.size != grant.size ||
          !verifiedModel.manifest.languages.contains(language)) {
        throw const ModelManifestChangedException();
      }
      await runs.runLocal(
        downloadId: grant.downloadId,
        modelVersion: grant.modelVersion,
        language: language,
        platform: grant.platform,
        sourceRevisionId: sourceRevisionId,
        sourceHash: sourceHash,
        selectedInkDocument: _freezeMap(selectedInkDocument),
        schemaVersion: schemaVersion,
        modelFile: verifiedModel.file,
        runtime: runtime,
        onStage: onStage,
        expectedSession: session,
        onRegistered: (run) async {
          session.requireCurrent();
          if (run.mode != 'local' ||
              run.status != 'registered' ||
              run.downloadId != grant.downloadId ||
              run.modelVersion != grant.modelVersion ||
              run.platform != grant.platform ||
              run.language != language ||
              run.sourceRevisionId != sourceRevisionId ||
              run.sourceHash != sourceHash) {
            throw const TranscriptionRunStateException();
          }
          drafts.saveDraft(
            noteId: noteId,
            accountId: session.accountId,
            runId: run.runId,
            downloadId: grant.downloadId,
            modelVersion: grant.modelVersion,
            platform: grant.platform,
            language: language,
            schemaVersion: schemaVersion,
            selectedSourceItemIds: selectedSourceItemIds,
            selectedInkDocument: _freezeMap(selectedInkDocument),
            sourceRevision: localSourceRevision,
            sourceRevisionId: sourceRevisionId,
            sourceHash: sourceHash,
            passages: const [],
          );
        },
      );
      session.requireCurrent();
      return _loadRecognizedDraft(
        noteId: noteId,
        session: session,
        selectedSourceItems: documentItems,
      );
    } finally {
      _starting.remove(key);
    }
  }

  /// Reopens a saved run for the current verified owner. Completed results are
  /// read back; a second run registration is never made.
  Future<TranscriptionDraft> resumeLocal({
    required String noteId,
    required TranscriptionRuntime runtime,
    required void Function(String stage) onStage,
  }) async {
    if (!drafts.hasDurableStorage ||
        !runs.hasDurableResultQueue ||
        !runs.hasDurableFeedbackQueue) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final session = await _requireSession();
    final draft = drafts.reopenDraft(noteId, accountId: session.accountId);
    if (draft == null ||
        draft.runId == null ||
        draft.downloadId == null ||
        draft.modelVersion == null ||
        draft.platform == null ||
        draft.language == null ||
        draft.schemaVersion == null ||
        draft.selectedInkDocument == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    if (draft.passages.isNotEmpty) return draft;
    final downloaded = await downloads.resume(
      downloadId: draft.downloadId!,
      version: draft.modelVersion!,
      platform: draft.platform!,
      expectedSession: session,
    );
    session.requireCurrent();
    if (downloaded.grant.downloadId != draft.downloadId ||
        downloaded.grant.modelVersion != draft.modelVersion ||
        downloaded.grant.platform != draft.platform ||
        !downloaded.manifest.languages.contains(draft.language)) {
      throw const ModelManifestChangedException();
    }
    final sourceItems = _selectedItems(draft.selectedInkDocument!);
    _validateSelection(sourceItems, draft.selectedSourceItemIds);
    await runs.resumeLocal(
      runId: draft.runId!,
      sourceRevisionId: draft.baseSourceRevisionId,
      sourceHash: draft.baseSourceHash,
      downloadId: draft.downloadId!,
      modelVersion: draft.modelVersion!,
      language: draft.language!,
      platform: draft.platform!,
      selectedInkDocument: draft.selectedInkDocument!,
      schemaVersion: draft.schemaVersion!,
      modelFile: downloaded.file,
      runtime: runtime,
      onStage: onStage,
      expectedSession: session,
    );
    session.requireCurrent();
    return _loadRecognizedDraft(
      noteId: noteId,
      session: session,
      selectedSourceItems: _selectedItems(draft.selectedInkDocument!),
    );
  }

  /// Persists a correction first, then queues/sends its mandatory feedback using
  /// the exact saved run and selected source sample. A delivery failure leaves
  /// the owner's correction and the existing durable retry event intact.
  Future<TranscriptionDraft> correctPassage({
    required String noteId,
    required String partId,
    required String correctedText,
  }) async {
    final session = await _requireSession();
    final prior = drafts.reopenDraft(noteId, accountId: session.accountId);
    if (prior == null || prior.runId == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final passage = prior.passages.where((item) => item.partId == partId);
    if (passage.length != 1) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final before = passage.single;
    final event = _feedbackEvent(
      draft: prior,
      passage: before,
      correction: correctedText,
      stage: 'intermediate',
    );
    drafts.applyUserCorrection(
      noteId,
      partId,
      correctedText: correctedText,
      accountId: session.accountId,
    );
    drafts.recordPendingFeedback(noteId, event, accountId: session.accountId);
    await runs.submitFeedback(
      runId: prior.runId!,
      events: [event],
      expectedSession: session,
    );
    session.requireCurrent();
    return drafts.acknowledgePendingFeedback(
      noteId,
      '${event['event_id']}',
      accountId: session.accountId,
    );
  }

  /// Explicitly accepts a reviewed correction. Repeated calls make fresh
  /// event ids; the server's idempotency is preserved for each frozen event.
  Future<TranscriptionDraft> acceptCorrection({
    required String noteId,
    required String partId,
  }) async {
    final session = await _requireSession();
    final draft = drafts.reopenDraft(noteId, accountId: session.accountId);
    if (draft == null || draft.runId == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final matches = draft.passages.where((item) => item.partId == partId);
    if (matches.length != 1 ||
        !matches.single.userCorrected ||
        matches.single.keepAsInk) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    if (matches.single.feedbackAccepted) return draft;
    final event = _feedbackEvent(
      draft: draft,
      passage: matches.single,
      correction: matches.single.text,
      stage: 'accepted',
    );
    drafts.recordPendingFeedback(noteId, event, accountId: session.accountId);
    await runs.submitFeedback(
      runId: draft.runId!,
      events: [event],
      expectedSession: session,
    );
    session.requireCurrent();
    drafts.acknowledgePendingFeedback(
      noteId,
      '${event['event_id']}',
      accountId: session.accountId,
    );
    return drafts.markFeedbackAccepted(
      noteId,
      partId,
      accountId: session.accountId,
    );
  }

  /// Keeps the original selected ink in the accepted Typed representation and
  /// records the owner's decision against that same selected sample.
  Future<TranscriptionDraft> keepPassageAsInk({
    required String noteId,
    required String partId,
  }) async {
    final session = await _requireSession();
    final draft = drafts.reopenDraft(noteId, accountId: session.accountId);
    if (draft == null || draft.runId == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final matches = draft.passages.where((item) => item.partId == partId);
    if (matches.length != 1) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final passage = matches.single;
    if (passage.feedbackAccepted) return draft;
    drafts.applyUserCorrection(
      noteId,
      partId,
      keepAsInk: true,
      accountId: session.accountId,
    );
    final event = _feedbackEvent(
      draft: draft,
      passage: passage,
      correction: '',
      stage: 'accepted',
    );
    drafts.recordPendingFeedback(noteId, event, accountId: session.accountId);
    await runs.submitFeedback(
      runId: draft.runId!,
      events: [event],
      expectedSession: session,
    );
    session.requireCurrent();
    drafts.acknowledgePendingFeedback(
      noteId,
      '${event['event_id']}',
      accountId: session.accountId,
    );
    return drafts.markFeedbackAccepted(
      noteId,
      partId,
      accountId: session.accountId,
    );
  }

  /// Retries saved events for the currently verified owner. The underlying
  /// queue retains the exact event id and body until the server acknowledges.
  Future<int> retryPendingFeedback() async {
    final session = await _requireSession();
    var delivered = await runs.retryPendingFeedback(expectedSession: session);
    for (final pending in drafts.pendingFeedbackForOwner(session.accountId)) {
      session.requireCurrent();
      await runs.submitFeedback(
        runId: pending.runId,
        events: [pending.event],
        expectedSession: session,
      );
      session.requireCurrent();
      final eventId = '${pending.event['event_id']}';
      drafts.acknowledgePendingFeedback(
        pending.noteId,
        eventId,
        accountId: session.accountId,
      );
      if (pending.event['stage'] == 'accepted' &&
          pending.event['segment_id'] is String) {
        drafts.markFeedbackAccepted(
          pending.noteId,
          pending.event['segment_id']! as String,
          accountId: session.accountId,
        );
      }
      delivered++;
    }
    session.requireCurrent();
    return delivered;
  }

  Future<TranscriptionDraft> _loadRecognizedDraft({
    required String noteId,
    required TranscriptionSession session,
    required List<Map<String, dynamic>> selectedSourceItems,
  }) async {
    final draft = drafts.reopenDraft(noteId, accountId: session.accountId);
    if (draft == null || draft.runId == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final result = await runs.readRun(draft.runId!, expectedSession: session);
    session.requireCurrent();
    if (result.runId != draft.runId ||
        result.mode != 'local' ||
        result.downloadId != draft.downloadId ||
        result.modelVersion != draft.modelVersion ||
        result.platform != draft.platform ||
        result.language != draft.language ||
        result.sourceRevisionId != draft.baseSourceRevisionId ||
        result.sourceHash != draft.baseSourceHash ||
        result.sourceStale) {
      throw const TranscriptionRunStateException();
    }
    final resultDocument = result.result?['document'];
    if (result.status != 'completed' || resultDocument is! Map) {
      return draft;
    }
    final passages = decodePassages(
      Map<String, Object?>.from(resultDocument),
      selectedSourceItems,
    );
    final passageIds = <String>{};
    for (final passage in passages) {
      final sourceIds = passage.sourceItemIds.isEmpty
          ? [passage.partId]
          : passage.sourceItemIds;
      if (passage.partId.trim().isEmpty ||
          passage.sourceHash.trim().isEmpty ||
          !passageIds.add(passage.partId) ||
          sourceIds.isEmpty ||
          sourceIds.toSet().length != sourceIds.length ||
          sourceIds.any((id) => !draft.selectedSourceItemIds.contains(id))) {
        throw const TranscriptionResultMappingException();
      }
    }
    session.requireCurrent();
    return drafts.saveRecognizedPassages(
      noteId,
      passages,
      accountId: session.accountId,
    );
  }

  Map<String, Object?> _feedbackEvent({
    required TranscriptionDraft draft,
    required TranscriptionPassage passage,
    required String correction,
    required String stage,
  }) {
    final sourceIds = passage.sourceItemIds.isNotEmpty
        ? passage.sourceItemIds
        : [
            passage.partId,
          ].where(draft.selectedSourceItemIds.contains).toList(growable: false);
    if (sourceIds.isEmpty ||
        sourceIds.any((id) => !draft.selectedSourceItemIds.contains(id)) ||
        draft.language == null ||
        draft.modelVersion == null) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    final strokes = _selectedInkItems(draft.selectedInkDocument!, sourceIds);
    if (strokes.isEmpty) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    return {
      'event_id': _newEventId(),
      'segment_id': passage.partId,
      'source_item_ids': sourceIds,
      'strokes': strokes,
      'suggestion': passage.text,
      'correction': correction,
      'stage': stage,
      'language': draft.language!,
      'model_version': draft.modelVersion!,
    };
  }

  Future<TranscriptionSession> _requireSession() async {
    final session = await sessionProvider();
    if (session == null) throw const TranscriptionSignInRequiredException();
    session.requireCurrent();
    return session;
  }

  void _validateSourceIdentity(String? revisionId, String? sourceHash) {
    if ((revisionId == null) == (sourceHash == null)) {
      throw ArgumentError(
        'Provide one authoritative source revision id or source hash.',
      );
    }
    if ((revisionId?.trim().isEmpty ?? false) ||
        (sourceHash != null && !_sha256.hasMatch(sourceHash))) {
      throw ArgumentError('The source identity is invalid.');
    }
  }

  void _validateSelection(
    List<Map<String, dynamic>> sourceItems,
    List<String> sourceIds,
  ) {
    if (sourceItems.isEmpty ||
        sourceIds.isEmpty ||
        sourceIds.any((id) => id.trim().isEmpty) ||
        sourceIds.toSet().length != sourceIds.length) {
      throw ArgumentError('Select at least one unique source item.');
    }
    final actualIds = sourceItems.map((item) => item['id']).toList();
    if (actualIds.any((id) => id is! String) ||
        actualIds.toSet().length != actualIds.length ||
        !setEquals(actualIds.cast<String>().toSet(), sourceIds.toSet())) {
      throw ArgumentError('The selected source ids do not match the sample.');
    }
  }

  void _validateSelectedDocument(
    List<Map<String, dynamic>> documentItems,
    List<Map<String, dynamic>> selectedSourceItems,
    List<String> selectedSourceItemIds,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final item in documentItems) {
      final id = item['id'];
      if (id is! String || id.isEmpty || byId.containsKey(id)) {
        throw ArgumentError('The selected document has invalid item ids.');
      }
      byId[id] = item;
    }
    final memberIds = <String>{};
    for (final item in documentItems) {
      if (item['kind'] != 'group') continue;
      final members = item['members'];
      if (members is! List || members.any((member) => member is! String)) {
        throw ArgumentError('The selected document has an invalid group.');
      }
      memberIds.addAll(members.cast<String>());
    }
    final roots = byId.keys.where((id) => !memberIds.contains(id)).toSet();
    if (!setEquals(roots, selectedSourceItemIds.toSet())) {
      throw ArgumentError(
        'The run document must contain only the selected source items.',
      );
    }
    for (final source in selectedSourceItems) {
      final id = source['id'] as String;
      if (jsonEncode(byId[id]) != jsonEncode(source)) {
        throw ArgumentError(
          'Selected source metadata does not match the run document.',
        );
      }
    }
    final reachable = <String>{};
    void visit(String id) {
      if (!reachable.add(id)) return;
      final item = byId[id];
      if (item == null) {
        throw ArgumentError('The selected group is missing a member.');
      }
      if (item['kind'] == 'group') {
        for (final member in (item['members'] as List).cast<String>()) {
          visit(member);
        }
      }
    }

    for (final id in roots) {
      visit(id);
    }
    if (!setEquals(reachable, byId.keys.toSet())) {
      throw ArgumentError(
        'The run document contains unselected or unreferenced items.',
      );
    }
  }

  List<Map<String, dynamic>> _selectedItems(Map<String, Object?> document) {
    final rawItems = document['items'];
    if (rawItems is! List || rawItems.any((item) => item is! Map)) {
      throw const TranscriptionWorkflowUnavailableException();
    }
    return rawItems
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  List<Map<String, Object?>> _selectedInkItems(
    Map<String, Object?> document,
    List<String> ids,
  ) {
    final allItems = _selectedItems(document);
    final byId = {for (final item in allItems) '${item['id']}': item};
    final selected = <String>{};
    void visit(String id) {
      if (!selected.add(id)) return;
      final item = byId[id];
      if (item == null) {
        throw const TranscriptionWorkflowUnavailableException();
      }
      if (item['kind'] == 'group') {
        final members = item['members'];
        if (members is! List || members.any((member) => member is! String)) {
          throw const TranscriptionWorkflowUnavailableException();
        }
        for (final member in members.cast<String>()) {
          visit(member);
        }
      }
    }

    for (final id in ids) {
      visit(id);
    }
    return [
      for (final item in allItems)
        if (selected.contains('${item['id']}') && item['kind'] == 'stroke')
          Map<String, Object?>.from(item),
    ];
  }

  Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
}

bool setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

String _newEventId() {
  final random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

final class TranscriptionWorkflowAlreadyExistsException implements Exception {
  const TranscriptionWorkflowAlreadyExistsException();
}

final class TranscriptionWorkflowUnavailableException implements Exception {
  const TranscriptionWorkflowUnavailableException();
}

final class TranscriptionResultMappingException implements Exception {
  const TranscriptionResultMappingException();
}

/// Resume always reads a completed result; it must not invoke a second model
/// pass if the persisted run is still registered. The coordinator treats that
/// state as unavailable until the runtime is reattached for explicit retry.
