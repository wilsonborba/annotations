import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../dal/remote/api_adapter.dart';

enum ContentJobKind {
  extraction('extraction'),
  studyNotes('study_notes');

  const ContentJobKind(this.code);
  final String code;
}

final class ContentJobSelectedFile {
  final String filename;
  final String contentType;
  final List<int> bytes;

  const ContentJobSelectedFile({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });
}

final class ContentJobRef {
  final String noteId;
  final String clientJobId;
  final String? jobId;
  final int lastEventSeq;
  final String status;
  final List<String> uploadedFileIds;

  const ContentJobRef({
    required this.noteId,
    required this.clientJobId,
    this.jobId,
    this.lastEventSeq = 0,
    required this.status,
    required this.uploadedFileIds,
  });

  ContentJobRef copyWith({
    String? jobId,
    int? lastEventSeq,
    String? status,
    List<String>? uploadedFileIds,
  }) => ContentJobRef(
    noteId: noteId,
    clientJobId: clientJobId,
    jobId: jobId ?? this.jobId,
    lastEventSeq: lastEventSeq ?? this.lastEventSeq,
    status: status ?? this.status,
    uploadedFileIds: uploadedFileIds ?? this.uploadedFileIds,
  );

  Map<String, Object?> toJson() => {
    'note_id': noteId,
    'client_job_id': clientJobId,
    'job_id': jobId,
    'last_event_seq': lastEventSeq,
    'status': status,
    'uploaded_file_ids': uploadedFileIds,
  };

  factory ContentJobRef.fromJson(Map<String, dynamic> j) => ContentJobRef(
    noteId: '${j['note_id']}',
    clientJobId: '${j['client_job_id']}',
    jobId: j['job_id'] as String?,
    lastEventSeq: (j['last_event_seq'] as num?)?.toInt() ?? 0,
    status: '${j['status'] ?? 'pending'}',
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

  Map<String, Object?> toJson() => {
    'note_id': noteId,
    'job_id': jobId,
    'extracted_text': extractedText,
    'accepted': accepted,
  };

  factory ContentJobDraft.fromJson(Map<String, dynamic> j) => ContentJobDraft(
    noteId: '${j['note_id']}',
    jobId: '${j['job_id']}',
    extractedText: '${j['extracted_text'] ?? ''}',
    accepted: (j['accepted'] as bool?) ?? false,
  );
}

abstract interface class ContentJobPersistence {
  Future<ContentJobRef?> loadRef(String noteId);
  Future<void> saveRef(ContentJobRef ref);
  Future<void> saveDraft(ContentJobDraft draft);
  Future<ContentJobDraft?> loadDraft(String noteId);
}

final class FileContentJobPersistence implements ContentJobPersistence {
  final File file;

  FileContentJobPersistence(this.file);

  Map<String, dynamic> _read() {
    if (!file.existsSync()) return {};
    return Map<String, dynamic>.from(
      jsonDecode(file.readAsStringSync()) as Map,
    );
  }

  void _write(Map<String, dynamic> data) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(data));
  }

  @override
  Future<ContentJobRef?> loadRef(String noteId) async {
    final refs = _read()['refs'];
    if (refs is! Map || refs[noteId] is! Map) return null;
    return ContentJobRef.fromJson(
      Map<String, dynamic>.from(refs[noteId] as Map),
    );
  }

  @override
  Future<void> saveRef(ContentJobRef ref) async {
    final data = _read();
    final refs = Map<String, dynamic>.from((data['refs'] as Map?) ?? const {});
    refs[ref.noteId] = ref.toJson();
    data['refs'] = refs;
    _write(data);
  }

  @override
  Future<ContentJobDraft?> loadDraft(String noteId) async {
    final drafts = _read()['drafts'];
    if (drafts is! Map || drafts[noteId] is! Map) return null;
    return ContentJobDraft.fromJson(
      Map<String, dynamic>.from(drafts[noteId] as Map),
    );
  }

  @override
  Future<void> saveDraft(ContentJobDraft draft) async {
    final data = _read();
    final drafts = Map<String, dynamic>.from(
      (data['drafts'] as Map?) ?? const {},
    );
    drafts[draft.noteId] = draft.toJson();
    data['drafts'] = drafts;
    _write(data);
  }
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
/// - Generates & persists `client_job_id` before any network call.
/// - Uploads ONLY selected files via `POST /me/files` (`purpose: content_job`) +
///   `PUT /me/files/{id}/content`, never `note_id` or full notes.
/// - Resumes SSE `GET /me/content_jobs/{id}/events` with `?after=<seq>` and `Last-Event-ID`.
class ContentJobService {
  final ApiAdapter api;
  final ContentJobPersistence persistence;
  final bool enabled;
  final Random _random = Random.secure();

  ContentJobService({
    required this.api,
    required this.persistence,
    this.enabled = false,
  });

  String _newClientJobId() {
    final n = _random.nextInt(1 << 30);
    return 'cj_${DateTime.now().microsecondsSinceEpoch}_$n';
  }

  /// Starts a content job only on explicit request when [enabled] is true.
  Future<ContentJobRef> startExplicitJob({
    required String noteId,
    required ContentJobKind kind,
    required List<ContentJobSelectedFile> selectedFiles,
  }) async {
    if (!enabled) {
      throw StateError('Cortex content jobs are disabled by default.');
    }
    if (selectedFiles.isEmpty) {
      throw ArgumentError('At least one selected file is required.');
    }

    // Generate & persist client_job_id BEFORE the first network call.
    final existing = await persistence.loadRef(noteId);
    final clientJobId = existing?.clientJobId ?? _newClientJobId();
    var ref =
        existing ??
        ContentJobRef(
          noteId: noteId,
          clientJobId: clientJobId,
          status: 'reserving',
          uploadedFileIds: const [],
        );
    await persistence.saveRef(ref);

    // Reserve + upload bytes only for selected files via `/me/files`.
    final uploadedIds = <String>[...ref.uploadedFileIds];
    if (uploadedIds.isEmpty) {
      for (final file in selectedFiles) {
        final reserved = await api.request(
          '/me/files',
          method: 'POST',
          body: {
            'purpose': 'content_job',
            'filename': file.filename,
            'content_type': file.contentType,
            'size_bytes': file.bytes.length,
          },
        );
        final fileId = '${reserved['file_id'] ?? reserved['id']}';
        final putReq = http.Request(
          'PUT',
          Uri.parse('${api.base}/me/files/$fileId/content'),
        );
        putReq.headers['content-type'] = file.contentType;
        putReq.bodyBytes = file.bytes;
        final putResp = await http.Response.fromStream(
          await api.client.send(putReq),
        );
        if (putResp.statusCode >= 400) {
          throw ApiError(putResp.statusCode, 'File upload failed');
        }
        uploadedIds.add(fileId);
      }
      ref = ref.copyWith(uploadedFileIds: uploadedIds, status: 'starting');
      await persistence.saveRef(ref);
    }

    final created = await api.request(
      '/me/content_jobs',
      method: 'POST',
      body: {
        'client_job_id': clientJobId,
        'kind': kind.code,
        'file_ids': uploadedIds,
      },
    );

    final updated = ref.copyWith(
      jobId: '${created['job_id'] ?? created['id']}',
      lastEventSeq:
          (created['last_event_seq'] as num?)?.toInt() ?? ref.lastEventSeq,
      status: '${created['status'] ?? 'queued'}',
    );
    await persistence.saveRef(updated);
    return updated;
  }

  /// Parses an SSE (`text/event-stream`) response body into `(seq, status)` pairs.
  static List<({int seq, String status})> parseSseFrames(String body) {
    final frames = <({int seq, String status})>[];
    int? currentId;
    String? currentEvent;
    final dataLines = <String>[];

    void flush() {
      if (dataLines.isEmpty && currentEvent == null && currentId == null) {
        return;
      }
      final dataStr = dataLines.join('\n');
      String status = currentEvent ?? 'running';
      if (dataStr.isNotEmpty) {
        try {
          final decoded = jsonDecode(dataStr);
          if (decoded is Map && decoded['status'] != null) {
            status = '${decoded['status']}';
          }
        } catch (_) {}
      }
      if (currentId != null) {
        frames.add((seq: currentId!, status: status));
      }
      currentId = null;
      currentEvent = null;
      dataLines.clear();
    }

    for (final line in const LineSplitter().convert(body)) {
      if (line.isEmpty) {
        flush();
      } else if (line.startsWith('id:')) {
        currentId = int.tryParse(line.substring(3).trim());
      } else if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      }
    }
    flush();
    return frames;
  }

  /// Resumes SSE events from `GET /me/content_jobs/{id}/events?after=<seq>` with
  /// `Last-Event-ID` header without re-uploading any files.
  Future<ContentJobDraft?> resumeJob(String noteId) async {
    if (!enabled) return null;
    final ref = await persistence.loadRef(noteId);
    if (ref == null || ref.jobId == null) return null;

    final uri = Uri.parse('${api.base}/me/content_jobs/${ref.jobId}/events')
        .replace(
          queryParameters: {
            if (ref.lastEventSeq > 0) 'after': '${ref.lastEventSeq}',
          },
        );
    final req = http.Request('GET', uri);
    req.headers['accept'] = 'text/event-stream';
    if (ref.lastEventSeq > 0) {
      req.headers['last-event-id'] = '${ref.lastEventSeq}';
    }
    final resp = await http.Response.fromStream(await api.client.send(req));
    if (resp.statusCode >= 400) {
      throw ApiError(resp.statusCode, 'Failed to read content job events');
    }

    var nextSeq = ref.lastEventSeq;
    var status = ref.status;
    final frames = parseSseFrames(resp.body);
    if (frames.isNotEmpty) {
      for (final f in frames) {
        if (f.seq > nextSeq) nextSeq = f.seq;
        status = f.status;
      }
    } else if (resp.body.trim().startsWith('{')) {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      nextSeq = (decoded['last_event_seq'] as num?)?.toInt() ?? nextSeq;
      status = '${decoded['status'] ?? status}';
    }

    await persistence.saveRef(
      ref.copyWith(lastEventSeq: nextSeq, status: status),
    );

    if (status == 'completed') {
      final job = await api.request('/me/content_jobs/${ref.jobId}');
      final draft = ContentJobDraft(
        noteId: noteId,
        jobId: ref.jobId!,
        extractedText: '${job['output_text'] ?? ''}',
        accepted: false,
      );
      await persistence.saveDraft(draft);
      return draft;
    }
    return null;
  }
}
