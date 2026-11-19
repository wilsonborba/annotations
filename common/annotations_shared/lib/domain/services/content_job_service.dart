import '../../dal/remote/api_adapter.dart';

final class ContentJobRef {
  final String noteId;
  final String jobId;
  final String? cursor;
  final String status;
  final List<String> uploadedFileIds;

  const ContentJobRef({
    required this.noteId,
    required this.jobId,
    this.cursor,
    required this.status,
    required this.uploadedFileIds,
  });

  ContentJobRef copyWith({
    String? cursor,
    String? status,
  }) =>
      ContentJobRef(
        noteId: noteId,
        jobId: jobId,
        cursor: cursor ?? this.cursor,
        status: status ?? this.status,
        uploadedFileIds: uploadedFileIds,
      );

  Map<String, Object?> toJson() => {
        'note_id': noteId,
        'job_id': jobId,
        'cursor': cursor,
        'status': status,
        'uploaded_file_ids': uploadedFileIds,
      };

  factory ContentJobRef.fromJson(Map<String, dynamic> j) => ContentJobRef(
        noteId: '${j['note_id']}',
        jobId: '${j['job_id']}',
        cursor: j['cursor'] as String?,
        status: '${j['status'] ?? 'queued'}',
        uploadedFileIds: ((j['uploaded_file_ids'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
      );
}

final class ContentJobDraft {
  final String noteId;
  final String jobId;
  final String extractedText;
  final bool accepted;

  const ContentJobDraft({
    required this.noteId,
    required this.jobId,
    required this.extractedText,
    this.accepted = false,
  });
}

abstract interface class ContentJobPersistence {
  Future<ContentJobRef?> loadRef(String noteId);
  Future<void> saveRef(ContentJobRef ref);
  Future<void> saveDraft(ContentJobDraft draft);
  Future<ContentJobDraft?> loadDraft(String noteId);
}

final class InMemoryContentJobPersistence implements ContentJobPersistence {
  final Map<String, ContentJobRef> _refs = {};
  final Map<String, ContentJobDraft> _drafts = {};

  @override
  Future<ContentJobRef?> loadRef(String noteId) async => _refs[noteId];

  @override
  Future<void> saveRef(ContentJobRef ref) async {
    _refs[ref.noteId] = ref;
  }

  @override
  Future<void> saveDraft(ContentJobDraft draft) async {
    _drafts[draft.noteId] = draft;
  }

  @override
  Future<ContentJobDraft?> loadDraft(String noteId) async => _drafts[noteId];
}

/// Optional Cortex content-job adapter with durable resume (annotations#47).
/// - Off by default (`enabled == false`).
/// - Local notes upload ONLY selected files through `/me/files`, never the whole note.
/// - Restarting resumes the saved `jobId` + `cursor` without a duplicate upload.
/// - Result is saved as a private draft; never overwrites accepted content or publishes.
class ContentJobService {
  final ApiAdapter api;
  final ContentJobPersistence persistence;
  final bool enabled;

  ContentJobService({
    required this.api,
    required this.persistence,
    this.enabled = false,
  });

  /// Starts a content job only on explicit request when [enabled] is true.
  Future<ContentJobRef> startExplicitJob({
    required String noteId,
    required String kind,
    required List<Map<String, Object?>> selectedFiles,
  }) async {
    if (!enabled) {
      throw StateError('Cortex content jobs are disabled by default.');
    }
    if (selectedFiles.isEmpty) {
      throw ArgumentError('At least one selected file is required.');
    }

    // Upload only the selected files via `/me/files`, never the whole note.
    final uploadedIds = <String>[];
    for (final file in selectedFiles) {
      final resp = await api.request(
        '/me/files',
        method: 'POST',
        body: file,
      );
      uploadedIds.add('${resp['file_id'] ?? resp['id']}');
    }

    final created = await api.request(
      '/me/content_jobs',
      method: 'POST',
      body: {
        'note_id': noteId,
        'kind': kind,
        'file_ids': uploadedIds,
      },
    );

    final ref = ContentJobRef(
      noteId: noteId,
      jobId: '${created['job_id'] ?? created['id']}',
      cursor: created['cursor'] as String?,
      status: '${created['status'] ?? 'queued'}',
      uploadedFileIds: uploadedIds,
    );
    await persistence.saveRef(ref);
    return ref;
  }

  /// Resumes the existing job after refresh, close, or restart without any new upload.
  Future<ContentJobDraft?> resumeJob(String noteId) async {
    if (!enabled) return null;
    final ref = await persistence.loadRef(noteId);
    if (ref == null) return null;

    final events = await api.request(
      '/me/content_jobs/${ref.jobId}/events',
      query: {
        if (ref.cursor != null && ref.cursor!.isNotEmpty) 'cursor': ref.cursor!,
      },
    );
    final nextCursor = (events['next_cursor'] as String?) ?? ref.cursor;
    final status = '${events['status'] ?? ref.status}';
    await persistence.saveRef(ref.copyWith(cursor: nextCursor, status: status));

    if (status == 'completed') {
      final job = await api.request('/me/content_jobs/${ref.jobId}');
      final draft = ContentJobDraft(
        noteId: noteId,
        jobId: ref.jobId,
        extractedText: '${job['output_text'] ?? ''}',
        accepted: false,
      );
      await persistence.saveDraft(draft);
      return draft;
    }
    return null;
  }
}
