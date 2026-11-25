import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/local_note.dart';
import '../../dal/remote/api_adapter.dart';
import 'native_auth_service.dart';

/// The chosen quiz setup. These values are sent to the server and are read
/// again from the durable study when Certifications resumes after a reload.
final class PreparedCertificationConfig {
  const PreparedCertificationConfig({this.language = 'en', this.count = 10});

  final String language;
  final int count;

  Map<String, Object> toJson() => {'language': language, 'count': count};

  factory PreparedCertificationConfig.fromJson(Map<String, dynamic> json) {
    final language = json['language'];
    final count = json['count'];
    if (!const {'en', 'pt-BR', 'th'}.contains(language) ||
        count is! int ||
        count < 1 ||
        count > 20) {
      throw const FormatException('Invalid saved Certifications config.');
    }
    return PreparedCertificationConfig(
      language: language as String,
      count: count,
    );
  }
}

/// One explicitly selected source for a prepared Certifications study.
final class PreparedCertificationSource {
  const PreparedCertificationSource({
    required this.kind,
    this.fileId,
    this.revisionId,
    this.selectionKind = 'all',
    this.selectionSpec,
  });

  final String kind;
  final String? fileId;
  final String? revisionId;
  final String selectionKind;
  final String? selectionSpec;

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (fileId != null) 'file_id': fileId,
    if (revisionId != null) 'revision_id': revisionId,
    'selection_kind': selectionKind,
    if (selectionSpec != null) 'selection_spec': selectionSpec,
  };
}

final class PreparedCertificationNoteSourceCatalog {
  const PreparedCertificationNoteSourceCatalog({
    required this.revision,
    required this.title,
    required this.noteSources,
    required this.fileIds,
  });

  final int revision;
  final String? title;
  final List<PreparedCertificationSource> noteSources;
  final List<String> fileIds;
}

final class PreparedCertificationStudy {
  const PreparedCertificationStudy({
    required this.id,
    required this.title,
    required this.status,
    required this.config,
  });

  final String id;
  final String title;
  final String status;

  /// A null value means the server has not returned durable setup yet.
  final PreparedCertificationConfig? config;
}

final class PreparedCertificationPersistenceException implements Exception {
  const PreparedCertificationPersistenceException();

  @override
  String toString() => 'The saved study config is unavailable.';
}

/// Notes API creation plus Certifications API reads for durable resume.
/// This service never starts generation and never stores setup in the client.
final class PreparedCertificationService {
  PreparedCertificationService({
    required this.api,
    required this.session,
    String? certificationsPath,
  }) : _certificationsApi = ApiAdapter(
         client: api.client,
         base: Uri.parse(api.base).origin,
       ),
       certificationsPath =
           certificationsPath ?? '/apps/certifications/v1/studies';

  final ApiAdapter api;
  final ApiAdapter _certificationsApi;
  final NativeSession session;
  final String certificationsPath;

  /// Reads current source revisions from the owner API. Local note content is
  /// never used to decide what the server will extract.
  Future<PreparedCertificationNoteSourceCatalog> readNoteSourceCatalog(
    String noteId,
  ) async {
    final response = await api.request(
      '/me/notes/${Uri.encodeComponent(noteId)}',
      headers: session.authHeaders(),
    );
    final revision = response['revision'];
    if (revision is! int || revision < 1) {
      throw ApiError(502, 'The service returned an invalid note revision.');
    }
    final representations = response['representations'];
    if (representations is! List) {
      throw ApiError(502, 'The service returned no note representations.');
    }
    final noteSources = <PreparedCertificationSource>[];
    final fileIds = <String>{};
    for (final raw in representations) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final name = item['representation'];
      final revisionId = item['revision_id'];
      final document = item['document'];
      if (name is! String || revisionId is! String || document is! Map) {
        continue;
      }
      final body = Map<String, dynamic>.from(document);
      if (name == 'original' && _hasOriginalText(body)) {
        noteSources.add(
          PreparedCertificationSource(
            kind: 'note_original',
            revisionId: revisionId,
          ),
        );
      } else if (name == 'typed' && _hasTypedText(body)) {
        noteSources.add(
          PreparedCertificationSource(
            kind: 'note_typed',
            revisionId: revisionId,
          ),
        );
      }
      _collectFileIds(body, fileIds);
    }
    return PreparedCertificationNoteSourceCatalog(
      revision: revision,
      title: response['title'] as String?,
      noteSources: List.unmodifiable(noteSources),
      fileIds: List.unmodifiable(fileIds),
    );
  }

  Future<PreparedCertificationStudy> create({
    required String noteId,
    required String title,
    required int expectedRevision,
    required List<PreparedCertificationSource> sources,
    required PreparedCertificationConfig config,
    String? description,
  }) async {
    if (sources.isEmpty || sources.length > 20) {
      throw ArgumentError.value(sources.length, 'sources');
    }
    final response = await api.request(
      '/me/notes/${Uri.encodeComponent(noteId)}/certifications/prepared',
      method: 'POST',
      headers: session.authHeaders(isMutation: true),
      body: {
        'title': title,
        'description': ?description,
        'expected_revision': expectedRevision,
        'sources': [for (final source in sources) source.toJson()],
        'config': config.toJson(),
      },
    );
    return _studyDetail(response, label: 'prepared study');
  }

  /// Creates the draft, then confirms that its chosen setup survived a server
  /// read before the browser opens. The create response is never a fallback.
  Future<PreparedCertificationStudy> prepare({
    required String noteId,
    required String title,
    required int expectedRevision,
    required List<PreparedCertificationSource> sources,
    required PreparedCertificationConfig config,
    String? description,
  }) async {
    final created = await create(
      noteId: noteId,
      title: title,
      expectedRevision: expectedRevision,
      sources: sources,
      config: config,
      description: description,
    );
    final saved = await read(created.id);
    if (saved.config?.language != config.language ||
        saved.config?.count != config.count) {
      throw const PreparedCertificationPersistenceException();
    }
    return saved;
  }

  /// Reads the server-owned study after creation or on resume. In particular,
  /// callers must not keep the POST response's config in memory as a fallback.
  Future<PreparedCertificationStudy> read(String studyId) async {
    if (studyId.trim().isEmpty) {
      throw ArgumentError.value(studyId, 'studyId');
    }
    final response = await _certificationsApi.request(
      '$certificationsPath/${Uri.encodeComponent(studyId)}',
      headers: session.authHeaders(),
    );
    return _studyDetail(response, label: 'study');
  }

  /// Reuses a ready owner file or uploads its local bytes after explicit
  /// selection. Unselected local attachments never reach this method.
  Future<String> prepareAttachmentSource({
    required String fileId,
    LocalAttachment? attachment,
    List<int>? bytes,
    bool Function()? isCurrent,
  }) async {
    if (attachment != null &&
        (bytes == null || bytes.isEmpty || bytes.length != attachment.size)) {
      throw ArgumentError('The selected attachment cannot be read.');
    }
    try {
      final existing = await api.request(
        '/me/files/${Uri.encodeComponent(fileId)}',
        headers: session.authHeaders(),
      );
      if (isCurrent != null && !isCurrent()) {
        throw StateError('The active account changed during source lookup.');
      }
      if (existing['status'] == 'ready') return fileId;
      throw ApiError(409, 'The selected file is not ready.');
    } on ApiError catch (error) {
      if (error.status != 404) rethrow;
    }
    if (isCurrent != null && !isCurrent()) {
      throw StateError('The active account changed before source upload.');
    }
    if (attachment == null || bytes == null) {
      throw ApiError(404, 'The selected file is not available.');
    }

    final reservation = await api.request(
      '/me/files',
      method: 'POST',
      headers: session.authHeaders(isMutation: true),
      body: {
        'purpose': 'attachment',
        'filename': attachment.name,
        'content_type': attachment.type,
        'size': bytes.length,
        'checksum': sha256.convert(bytes).toString(),
      },
    );
    final uploadedFileId = reservation['file_id'] ?? reservation['id'];
    if (uploadedFileId is! String || uploadedFileId.isEmpty) {
      throw ApiError(502, 'The service returned an invalid file reservation.');
    }
    if (isCurrent != null && !isCurrent()) {
      throw StateError('The active account changed before source upload.');
    }
    final request =
        http.Request(
            'PUT',
            Uri.parse(
              '${api.base}/me/files/${Uri.encodeComponent(uploadedFileId)}/content',
            ),
          )
          ..headers.addAll(session.authHeaders(isMutation: true))
          ..headers['content-type'] = attachment.type
          ..bodyBytes = bytes;
    final response = await http.Response.fromStream(
      await api.client.send(request),
    );
    if (response.statusCode >= 400) {
      throw ApiError(
        response.statusCode,
        'The selected file could not upload.',
      );
    }
    return uploadedFileId;
  }

  static bool _hasOriginalText(Map<String, dynamic> document) {
    final items = document['items'];
    if (items is! List) return false;
    bool collect(List values) {
      for (final raw in values) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        if (item['kind'] == 'text' && _hasSpans(item['spans'])) return true;
        if (item['kind'] == 'group' && item['items'] is List) {
          if (collect(item['items'] as List)) return true;
        }
      }
      return false;
    }

    return collect(items);
  }

  static bool _hasTypedText(Map<String, dynamic> document) {
    final blocks = document['blocks'];
    if (blocks is! List) return false;
    for (final raw in blocks) {
      if (raw is! Map) continue;
      final block = Map<String, dynamic>.from(raw);
      switch (block['kind']) {
        case 'heading' || 'paragraph':
          if (_hasSpans(block['spans'])) return true;
        case 'list':
          final items = block['items'];
          if (items is List &&
              items.any((item) => item is Map && _hasSpans(item['spans']))) {
            return true;
          }
        case 'table':
          final rows = block['rows'];
          if (rows is List) {
            for (final row in rows.whereType<Map>()) {
              final cells = row['cells'];
              if (cells is List &&
                  cells.any(
                    (cell) => cell is Map && _hasSpans(cell['spans']),
                  )) {
                return true;
              }
            }
          }
        case 'figure':
          if (_hasSpans(block['caption'])) return true;
      }
    }
    return false;
  }

  static bool _hasSpans(Object? value) =>
      value is List &&
      value.any(
        (span) =>
            span is Map &&
            span['text'] is String &&
            (span['text'] as String).trim().isNotEmpty,
      );

  static void _collectFileIds(Object? value, Set<String> fileIds) {
    if (value is Map) {
      final id = value['file_id'];
      if (id is String && id.isNotEmpty) fileIds.add(id);
      for (final child in value.values) {
        _collectFileIds(child, fileIds);
      }
    } else if (value is List) {
      for (final child in value) {
        _collectFileIds(child, fileIds);
      }
    }
  }

  PreparedCertificationStudy _studyDetail(
    Map<String, dynamic> detail, {
    required String label,
  }) {
    // Certifications returns StudyDetail: config is a sibling of `study`,
    // while `study` itself is only the StudySummary.
    final study = detail['study'];
    if (study is! Map) {
      throw ApiError(502, 'The service returned an invalid $label.');
    }
    final config = detail['config'];
    if (config != null && config is! Map) {
      throw ApiError(502, 'The service returned an invalid study config.');
    }
    return _study(
      Map<String, dynamic>.from(study),
      config: config == null ? null : Map<String, dynamic>.from(config),
    );
  }

  PreparedCertificationStudy _study(
    Map<String, dynamic> json, {
    required Map<String, dynamic>? config,
  }) {
    final id = json['id'];
    final title = json['title'];
    final status = json['status'];
    if (id is! String ||
        id.trim().isEmpty ||
        title is! String ||
        status is! String) {
      throw ApiError(502, 'The service returned an invalid study summary.');
    }
    return PreparedCertificationStudy(
      id: id,
      title: title,
      status: status,
      config: config != null
          ? PreparedCertificationConfig.fromJson(config)
          : null,
    );
  }
}
