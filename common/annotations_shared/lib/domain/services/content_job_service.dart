import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../dal/remote/api_adapter.dart';
import '../models/transcription_session.dart';

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

final class ContentJobReviewState {
  const ContentJobReviewState({this.ref, this.draft});

  final ContentJobRef? ref;
  final ContentJobDraft? draft;
}

abstract interface class ContentJobPersistence {
  Future<ContentJobRef?> loadRef(String accountId, String noteId);
  Future<void> saveRef(String accountId, ContentJobRef ref);
  Future<void> saveDraft(String accountId, ContentJobDraft draft);
  Future<ContentJobDraft?> loadDraft(String accountId, String noteId);
  Future<void> finishDraft(
    String accountId,
    String noteId,
    String jobId, {
    required bool inserted,
  });
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

  // Older note-only keys are intentionally left untouched and never adopted:
  // their owner cannot be established safely.
  String _key(String accountId, String noteId) =>
      jsonEncode([accountId, noteId]);

  void _write(Map<String, dynamic> data) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(data));
  }

  @override
  Future<ContentJobRef?> loadRef(String accountId, String noteId) async {
    final refs = _read()['refs'];
    final key = _key(accountId, noteId);
    if (refs is! Map || refs[key] is! Map) return null;
    return ContentJobRef.fromJson(Map<String, dynamic>.from(refs[key] as Map));
  }

  @override
  Future<void> saveRef(String accountId, ContentJobRef ref) async {
    final data = _read();
    final refs = Map<String, dynamic>.from((data['refs'] as Map?) ?? const {});
    refs[_key(accountId, ref.noteId)] = ref.toJson();
    data['refs'] = refs;
    _write(data);
  }

  @override
  Future<ContentJobDraft?> loadDraft(String accountId, String noteId) async {
    final drafts = _read()['drafts'];
    final key = _key(accountId, noteId);
    if (drafts is! Map || drafts[key] is! Map) return null;
    return ContentJobDraft.fromJson(
      Map<String, dynamic>.from(drafts[key] as Map),
    );
  }

  @override
  Future<void> saveDraft(String accountId, ContentJobDraft draft) async {
    final data = _read();
    final drafts = Map<String, dynamic>.from(
      (data['drafts'] as Map?) ?? const {},
    );
    drafts[_key(accountId, draft.noteId)] = draft.toJson();
    data['drafts'] = drafts;
    _write(data);
  }

  @override
  Future<void> finishDraft(
    String accountId,
    String noteId,
    String jobId, {
    required bool inserted,
  }) async {
    final data = _read();
    final key = _key(accountId, noteId);
    final refs = Map<String, dynamic>.from((data['refs'] as Map?) ?? const {});
    final rawRef = refs[key];
    if (rawRef is! Map || rawRef['job_id'] != jobId) {
      throw StateError(
        'The content job changed before the result was handled.',
      );
    }
    refs[key] = ContentJobRef.fromJson(Map<String, dynamic>.from(rawRef))
        .copyWith(status: inserted ? 'result_inserted' : 'result_discarded')
        .toJson();
    data['refs'] = refs;
    final drafts = Map<String, dynamic>.from(
      (data['drafts'] as Map?) ?? const {},
    );
    final rawDraft = drafts[key];
    if (rawDraft is! Map || rawDraft['job_id'] != jobId) {
      throw StateError('The saved content job result changed.');
    }
    if (inserted) {
      final draft = ContentJobDraft.fromJson(
        Map<String, dynamic>.from(rawDraft),
      );
      drafts[key] = ContentJobDraft(
        noteId: draft.noteId,
        jobId: draft.jobId,
        extractedText: draft.extractedText,
        accepted: true,
      ).toJson();
    } else {
      drafts.remove(key);
    }
    data['drafts'] = drafts;
    _write(data);
  }
}

final class InMemoryContentJobPersistence implements ContentJobPersistence {
  final Map<String, ContentJobRef> _refs = {};
  final Map<String, ContentJobDraft> _drafts = {};

  String _key(String accountId, String noteId) =>
      jsonEncode([accountId, noteId]);

  @override
  Future<ContentJobRef?> loadRef(String accountId, String noteId) async =>
      _refs[_key(accountId, noteId)];

  @override
  Future<void> saveRef(String accountId, ContentJobRef ref) async {
    _refs[_key(accountId, ref.noteId)] = ref;
  }

  @override
  Future<void> saveDraft(String accountId, ContentJobDraft draft) async {
    _drafts[_key(accountId, draft.noteId)] = draft;
  }

  @override
  Future<ContentJobDraft?> loadDraft(String accountId, String noteId) async =>
      _drafts[_key(accountId, noteId)];

  @override
  Future<void> finishDraft(
    String accountId,
    String noteId,
    String jobId, {
    required bool inserted,
  }) async {
    final key = _key(accountId, noteId);
    final draft = _drafts[key];
    final ref = _refs[key];
    if (draft?.jobId != jobId || ref?.jobId != jobId) {
      throw StateError('The saved content job result changed.');
    }
    _refs[key] = ref!.copyWith(
      status: inserted ? 'result_inserted' : 'result_discarded',
    );
    if (inserted) {
      _drafts[key] = ContentJobDraft(
        noteId: draft!.noteId,
        jobId: draft.jobId,
        extractedText: draft.extractedText,
        accepted: true,
      );
    } else {
      _drafts.remove(key);
    }
  }
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
  final TranscriptionSessionProvider? sessionProvider;
  final Random _random = Random.secure();

  ContentJobService({
    required this.api,
    required this.persistence,
    this.enabled = false,
    this.sessionProvider,
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
    final session = await _verifiedSession();
    session.requireCurrent();
    if (selectedFiles.isEmpty) {
      throw ArgumentError('At least one selected file is required.');
    }

    // Generate & persist client_job_id BEFORE the first network call.
    var existing = await persistence.loadRef(session.accountId, noteId);
    session.requireCurrent();
    if (existing?.status == 'result_inserted' ||
        existing?.status == 'result_discarded') {
      existing = null;
    }
    final clientJobId = existing?.clientJobId ?? _newClientJobId();
    var ref =
        existing ??
        ContentJobRef(
          noteId: noteId,
          clientJobId: clientJobId,
          status: 'reserving',
          uploadedFileIds: const [],
        );
    session.requireCurrent();
    await persistence.saveRef(session.accountId, ref);
    session.requireCurrent();

    // Reserve + upload bytes only for selected files via `/me/files`.
    final uploadedIds = <String>[...ref.uploadedFileIds];
    if (uploadedIds.isEmpty) {
      for (final file in selectedFiles) {
        final checksum = sha256.convert(file.bytes).toString();
        session.requireCurrent();
        final reserved = await api.request(
          '/me/files',
          method: 'POST',
          headers: session.headers(mutation: true),
          body: {
            'purpose': 'content_job',
            'filename': file.filename,
            'content_type': file.contentType,
            'size': file.bytes.length,
            'checksum': checksum,
          },
        );
        session.requireCurrent();
        final fileId = '${reserved['file_id'] ?? reserved['id']}';
        final putReq = http.Request(
          'PUT',
          Uri.parse('${api.base}/me/files/$fileId/content'),
        );
        putReq.headers['content-type'] = file.contentType;
        putReq.headers.addAll(session.headers(mutation: true));
        putReq.bodyBytes = file.bytes;
        session.requireCurrent();
        final putResp = await http.Response.fromStream(
          await api.client.send(putReq),
        );
        session.requireCurrent();
        if (putResp.statusCode >= 400) {
          throw ApiError(putResp.statusCode, 'File upload failed');
        }
        uploadedIds.add(fileId);
      }
      ref = ref.copyWith(uploadedFileIds: uploadedIds, status: 'starting');
      session.requireCurrent();
      await persistence.saveRef(session.accountId, ref);
      session.requireCurrent();
    }

    session.requireCurrent();
    final created = await api.request(
      '/me/content_jobs',
      method: 'POST',
      headers: session.headers(mutation: true),
      body: {
        'client_job_id': clientJobId,
        'kind': kind.code,
        'file_ids': uploadedIds,
      },
    );
    session.requireCurrent();

    final updated = ref.copyWith(
      jobId: '${created['job_id'] ?? created['id']}',
      lastEventSeq:
          (created['last_event_seq'] as num?)?.toInt() ?? ref.lastEventSeq,
      status: '${created['status'] ?? 'queued'}',
    );
    await persistence.saveRef(session.accountId, updated);
    session.requireCurrent();
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
  Future<ContentJobDraft?> resumeJob(
    String noteId, {
    void Function(int sequence, String status)? onProgress,
  }) async {
    if (!enabled) return null;
    final session = await _verifiedSession();
    session.requireCurrent();
    final ref = await persistence.loadRef(session.accountId, noteId);
    session.requireCurrent();
    if (ref == null || ref.jobId == null) return null;
    if (ref.status == 'result_inserted' || ref.status == 'result_discarded') {
      return null;
    }
    final savedDraft = await persistence.loadDraft(session.accountId, noteId);
    session.requireCurrent();
    if (savedDraft != null) return savedDraft.accepted ? null : savedDraft;

    final uri = Uri.parse('${api.base}/me/content_jobs/${ref.jobId}/events')
        .replace(
          queryParameters: {
            if (ref.lastEventSeq > 0) 'after': '${ref.lastEventSeq}',
          },
        );
    final req = http.Request('GET', uri);
    req.headers['accept'] = 'text/event-stream';
    req.headers.addAll(session.headers(mutation: false));
    if (ref.lastEventSeq > 0) {
      req.headers['last-event-id'] = '${ref.lastEventSeq}';
    }
    session.requireCurrent();
    final response = await api.client.send(req);
    try {
      session.requireCurrent();
    } on TranscriptionSessionChangedException {
      // The headers arrived after this account snapshot expired. This stream
      // belongs to this request, so cancel only its body subscription; the
      // shared ApiAdapter client remains available to other requests.
      await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
      rethrow;
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
      session.requireCurrent();
      throw ApiError(response.statusCode, 'Failed to read content job events');
    }

    var nextSeq = ref.lastEventSeq;
    var status = ref.status;
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.toLowerCase().contains('application/json')) {
      final body = await response.stream.bytesToString();
      session.requireCurrent();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid content job event response.');
      }
      nextSeq = (decoded['last_event_seq'] as num?)?.toInt() ?? nextSeq;
      status = '${decoded['status'] ?? status}';
    } else {
      await for (final frame in _parseContentJobSse(response.stream)) {
        session.requireCurrent();
        if (frame.seq <= nextSeq) continue;
        nextSeq = frame.seq;
        status = frame.status;
        await persistence.saveRef(
          session.accountId,
          ref.copyWith(lastEventSeq: nextSeq, status: status),
        );
        session.requireCurrent();
        onProgress?.call(frame.seq, frame.status);
      }
    }

    session.requireCurrent();
    await persistence.saveRef(
      session.accountId,
      ref.copyWith(lastEventSeq: nextSeq, status: status),
    );
    session.requireCurrent();

    if (status == 'completed') {
      final job = await api.request(
        '/me/content_jobs/${ref.jobId}',
        headers: session.headers(mutation: false),
      );
      session.requireCurrent();
      final rawDraft = job['draft'];
      if (job['job_id'] != ref.jobId ||
          rawDraft is! Map ||
          rawDraft['format'] != 'markdown' ||
          rawDraft['text'] is! String ||
          (rawDraft['text'] as String).trim().isEmpty) {
        throw const FormatException('Invalid completed content job draft.');
      }
      final draft = ContentJobDraft(
        noteId: noteId,
        jobId: ref.jobId!,
        extractedText: rawDraft['text'] as String,
        accepted: false,
      );
      await persistence.saveDraft(session.accountId, draft);
      session.requireCurrent();
      return draft;
    }
    return null;
  }

  Future<TranscriptionSession> _verifiedSession() async {
    final provider = sessionProvider;
    if (provider == null) throw const TranscriptionSignInRequiredException();
    final session = await provider();
    if (session == null) throw const TranscriptionSignInRequiredException();
    session.requireCurrent();
    return session;
  }

  Future<ContentJobReviewState> loadReviewState(String noteId) async {
    if (!enabled) return const ContentJobReviewState();
    final session = await _verifiedSession();
    final ref = await persistence.loadRef(session.accountId, noteId);
    session.requireCurrent();
    final draft = await persistence.loadDraft(session.accountId, noteId);
    session.requireCurrent();
    return ContentJobReviewState(ref: ref, draft: draft);
  }

  /// Marks a result as inserted into the local note. The draft remains
  /// durable so resume cannot insert it a second time after reopening.
  Future<void> markDraftInserted(String noteId, String jobId) async {
    if (!enabled) throw StateError('Cortex content jobs are disabled.');
    final session = await _verifiedSession();
    final draft = await persistence.loadDraft(session.accountId, noteId);
    session.requireCurrent();
    if (draft == null || draft.jobId != jobId) {
      throw StateError('The saved content job result changed.');
    }
    await persistence.finishDraft(
      session.accountId,
      noteId,
      jobId,
      inserted: true,
    );
    session.requireCurrent();
  }

  /// Discards only this owner's local review result; server history and
  /// uploaded files remain governed by the content-job API.
  Future<void> discardDraft(String noteId, String jobId) async {
    if (!enabled) throw StateError('Cortex content jobs are disabled.');
    final session = await _verifiedSession();
    final draft = await persistence.loadDraft(session.accountId, noteId);
    session.requireCurrent();
    if (draft == null || draft.jobId != jobId) return;
    await persistence.finishDraft(
      session.accountId,
      noteId,
      jobId,
      inserted: false,
    );
    session.requireCurrent();
  }
}

Stream<({int seq, String status})> _parseContentJobSse(
  Stream<List<int>> bytes,
) async* {
  const maxFrameCharacters = 64 * 1024;
  int? id;
  String? event;
  final data = <String>[];
  var frameCharacters = 0;

  ({int seq, String status})? flush() {
    final eventId = id;
    if (eventId == null) return null;
    var status = event ?? 'running';
    if (data.isNotEmpty) {
      final decoded = jsonDecode(data.join('\n'));
      if (decoded is Map && decoded['status'] is String) {
        status = decoded['status'] as String;
      }
    }
    return (seq: eventId, status: status);
  }

  ({int seq, String status})? consumeLine(String line) {
    frameCharacters += line.length + 1;
    if (frameCharacters > maxFrameCharacters) {
      throw const FormatException('Content job event frame is too large.');
    }
    if (line.isEmpty) {
      final frame = flush();
      id = null;
      event = null;
      data.clear();
      frameCharacters = 0;
      return frame;
    }
    if (line.startsWith(':')) return null;
    if (line.startsWith('id:')) {
      id = int.tryParse(line.substring(3).trim());
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).trim());
    }
    return null;
  }

  var pendingLine = '';
  await for (final chunk in bytes.transform(utf8.decoder)) {
    final text = pendingLine + chunk;
    var lineStart = 0;
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code != 10 && code != 13) continue;
      if (code == 13 && i == text.length - 1) break;
      final frame = consumeLine(text.substring(lineStart, i));
      if (frame != null) yield frame;
      if (code == 13 && text.codeUnitAt(i + 1) == 10) i++;
      lineStart = i + 1;
    }
    pendingLine = text.substring(lineStart);
    if (pendingLine.length > maxFrameCharacters) {
      throw const FormatException('Content job event line is too large.');
    }
  }

  if (pendingLine.endsWith('\r')) {
    final frame = consumeLine(pendingLine.substring(0, pendingLine.length - 1));
    if (frame != null) yield frame;
    final finalFrame = consumeLine('');
    if (finalFrame != null) yield finalFrame;
  } else if (pendingLine.isNotEmpty) {
    final frame = consumeLine(pendingLine);
    if (frame != null) yield frame;
  }
  final finalFrame = flush();
  if (finalFrame != null) yield finalFrame;
}
