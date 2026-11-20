import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Strict contract fake matching `annotations_api` request validation.
///
/// Rejects unknown fields and missing required fields with the exact HTTP status
/// and error code used by `annotations_api` so client tests fail whenever a
/// request body drifts from the backend contract.
class AnnotationsApiContract {
  final Future<http.Response> Function(
    http.Request req,
    Map<String, dynamic>? jsonBody,
  )
  onValid;

  AnnotationsApiContract({required this.onValid});

  MockClient toMockClient() {
    return MockClient((req) async {
      final rawBytes = req.headers['content-encoding'] == 'gzip'
          ? gzip.decode(req.bodyBytes)
          : req.bodyBytes;
      Map<String, dynamic>? body;
      if (rawBytes.isNotEmpty &&
          (req.headers['content-type']?.contains('application/json') ??
              false ||
                  req.method == 'POST' ||
                  req.method == 'PUT' ||
                  req.method == 'PATCH')) {
        if (req.url.path.endsWith('/content')) {
          body = null;
        } else {
          final decoded = jsonDecode(utf8.decode(rawBytes));
          if (decoded is! Map) {
            return _err(422, 'invalid_request', 'The body is one JSON object');
          }
          body = Map<String, dynamic>.from(decoded);
        }
      }

      final violation = validate(req, body);
      if (violation != null) return violation;
      return onValid(req, body);
    });
  }

  /// Validates [req] and [body] against `annotations_api` route contracts.
  /// Returns an error [http.Response] if invalid, or `null` if valid.
  http.Response? validate(http.Request req, Map<String, dynamic>? body) {
    var path = req.url.path;
    const apiPrefix = '/apps/annotations/v1';
    if (path.startsWith(apiPrefix)) path = path.substring(apiPrefix.length);
    final method = req.method.toUpperCase();

    // POST /me/notes -> annotations_api/lib/domain/notes.rs::create
    if (method == 'POST' && path == '/me/notes') {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'client_note_id',
        'main_representation',
        'metadata',
        'representations',
        'project_ids',
      }, '');
      if (unknown != null) return unknown;
      final cid = b['client_note_id'];
      if (cid is! String || cid.isEmpty || cid.length > 128) {
        return _err(
          422,
          'invalid_client_note_id',
          'The client note id uses 1 to 128 visible ASCII characters',
        );
      }
      final reps = b['representations'];
      if (reps is! Map || reps.isEmpty) {
        return _err(
          422,
          'representation_required',
          'A new note needs at least one representation',
        );
      }
      final repMap = Map<String, dynamic>.from(reps);
      final repUnknown = _unknownField(
        repMap,
        const {'original', 'typed'},
        'representations.',
      );
      if (repUnknown != null) return repUnknown;
      for (final e in repMap.entries) {
        if (e.value is! Map) {
          return _err(
            422,
            'invalid_type',
            'The value has the wrong type: representations.${e.key}',
          );
        }
        final docMap = Map<String, dynamic>.from(e.value as Map);
        final docUnknown = _unknownField(
          docMap,
          const {'schema_version', 'document'},
          'representations.${e.key}.',
        );
        if (docUnknown != null) return docUnknown;
        if (docMap['document'] is! Map) {
          return _err(
            422,
            'missing_field',
            'A required field is missing: representations.${e.key}.document',
          );
        }
      }
      if (b['metadata'] != null) {
        final metaCheck = _validateMetadata(b['metadata']);
        if (metaCheck != null) return metaCheck;
      }
      return null;
    }

    // PUT /me/notes/{id} -> annotations_api/lib/domain/notes.rs::replace
    if (method == 'PUT' &&
        RegExp(r'^/me/notes/[^/]+$').hasMatch(path)) {
      if (_missingIfMatch(req)) {
        return _err(
          428,
          'if_match_required',
          'Send the note revision in the If-Match header',
        );
      }
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'representation',
        'schema_version',
        'document',
        'transcription_run_id',
      }, '');
      if (unknown != null) return unknown;
      final rep = b['representation'];
      if (rep != 'original' && rep != 'typed') {
        return _err(
          422,
          'invalid_type',
          'The value has the wrong type: representation',
        );
      }
      if (b['document'] is! Map) {
        return _err(
          422,
          'missing_field',
          'A required field is missing: document',
        );
      }
      return null;
    }

    // PATCH /me/notes/{id} -> annotations_api/lib/domain/notes.rs::patch
    if (method == 'PATCH' &&
        RegExp(r'^/me/notes/[^/]+$').hasMatch(path)) {
      if (_missingIfMatch(req)) {
        return _err(
          428,
          'if_match_required',
          'Send the note revision in the If-Match header',
        );
      }
      final b = body ?? const {};
      if (b.containsKey('typed')) {
        return _err(
          422,
          'typed_operations_unsupported',
          'Replace the typed representation with PUT',
        );
      }
      final unknown = _unknownField(b, const {'original', 'metadata'}, '');
      if (unknown != null) return unknown;
      if (b['metadata'] != null) {
        final metaCheck = _validateMetadata(b['metadata']);
        if (metaCheck != null) return metaCheck;
      }
      return null;
    }

    // DELETE /me/notes/{id} -> annotations_api/lib/domain/notes.rs::delete
    if (method == 'DELETE' &&
        RegExp(r'^/me/notes/[^/]+$').hasMatch(path)) {
      if (_missingIfMatch(req)) {
        return _err(
          428,
          'if_match_required',
          'Send the note revision in the If-Match header',
        );
      }
      return null;
    }

    // PUT /me/notes/{id}/publication -> annotations_api/lib/domain/publication.rs::put
    if (method == 'PUT' &&
        RegExp(r'^/me/notes/[^/]+/publication$').hasMatch(path)) {
      if (_missingIfMatch(req)) {
        return _err(
          428,
          'if_match_required',
          'Send the note revision in the If-Match header',
        );
      }
      final b = body ?? const {};
      final unknown = _unknownField(b, const {'language', 'representations'}, '');
      if (unknown != null) return unknown;
      final lang = b['language'];
      if (lang is! String || lang.isEmpty) {
        return _err(
          422,
          'missing_field',
          'A required field is missing: language',
        );
      }
      final reps = b['representations'];
      if (reps is! Map || reps.isEmpty) {
        return _err(
          422,
          'representation_required',
          'Publish at least one representation; use DELETE to unpublish',
        );
      }
      final repMap = Map<String, dynamic>.from(reps);
      final repUnknown = _unknownField(
        repMap,
        const {'original', 'typed'},
        'representations.',
      );
      if (repUnknown != null) return repUnknown;
      for (final e in repMap.entries) {
        if (e.value is! String || (e.value as String).isEmpty) {
          return _err(
            422,
            'invalid_type',
            'The value has the wrong type: representations.${e.key}',
          );
        }
      }
      return null;
    }

    // DELETE /me/notes/{id}/publication -> annotations_api/lib/domain/publication.rs::delete
    if (method == 'DELETE' &&
        RegExp(r'^/me/notes/[^/]+/publication$').hasMatch(path)) {
      if (_missingIfMatch(req)) {
        return _err(
          428,
          'if_match_required',
          'Send the note revision in the If-Match header',
        );
      }
      return null;
    }

    // POST /instant/{code}/files -> annotations_api/lib/domain/transfers.rs::Metadata
    if (method == 'POST' &&
        RegExp(r'^/instant/[^/]+/files$').hasMatch(path)) {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'filename',
        'content_type',
        'size',
        'checksum',
      }, '');
      if (unknown != null) return unknown;
      return _validateFileFields(b, requirePurpose: false);
    }

    // POST /me/files -> annotations_api/lib/domain/files.rs::Reservation::parse
    if (method == 'POST' && path == '/me/files') {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'filename',
        'content_type',
        'size',
        'checksum',
        'purpose',
      }, '');
      if (unknown != null) return unknown;
      return _validateFileFields(b, requirePurpose: true);
    }

    // POST /me/content_jobs -> annotations_api/lib/domain/transcriptions.rs
    if (method == 'POST' && path == '/me/content_jobs') {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'client_job_id',
        'kind',
        'file_ids',
      }, '');
      if (unknown != null) return unknown;
      if (b['client_job_id'] is! String ||
          (b['client_job_id'] as String).isEmpty) {
        return _err(422, 'missing_field', 'client_job_id is required');
      }
      if (b['kind'] != 'extraction' && b['kind'] != 'study_notes') {
        return _err(422, 'invalid_kind', 'kind must be extraction or study_notes');
      }
      if (b['file_ids'] is! List || (b['file_ids'] as List).isEmpty) {
        return _err(422, 'missing_field', 'file_ids is required');
      }
      return null;
    }

    // POST /me/tasks -> annotations_api/lib/domain/tasks.rs
    if (method == 'POST' && path == '/me/tasks') {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'title',
        'status',
        'due_at',
        'note_id',
      }, '');
      if (unknown != null) return unknown;
      if (b['status'] != null &&
          b['status'] != 'open' &&
          b['status'] != 'completed') {
        return _err(422, 'invalid_status', 'status must be open or completed');
      }
      return null;
    }

    // PATCH /me/tasks/{id} -> annotations_api/lib/domain/tasks.rs
    if (method == 'PATCH' && RegExp(r'^/me/tasks/[^/]+$').hasMatch(path)) {
      final b = body ?? const {};
      final unknown = _unknownField(b, const {
        'title',
        'status',
        'due_at',
        'note_id',
      }, '');
      if (unknown != null) return unknown;
      if (b['status'] != null &&
          b['status'] != 'open' &&
          b['status'] != 'completed') {
        return _err(422, 'invalid_status', 'status must be open or completed');
      }
      return null;
    }

    return null;
  }

  static bool _missingIfMatch(http.Request req) =>
      !req.headers.keys.any((k) => k.toLowerCase() == 'if-match');

  static http.Response? _unknownField(
    Map<String, dynamic> map,
    Set<String> allowed,
    String prefix,
  ) {
    final unknown = map.keys.where((k) => !allowed.contains(k)).toList()..sort();
    if (unknown.isEmpty) return null;
    return _err(
      422,
      'unknown_field',
      'The field is not allowed here: $prefix${unknown.first}',
    );
  }

  static http.Response? _validateMetadata(Object? raw) {
    if (raw is! Map) {
      return _err(
        422,
        'invalid_type',
        'The value has the wrong type: metadata',
      );
    }
    return _unknownField(
      Map<String, dynamic>.from(raw),
      const {'title', 'tags'},
      'metadata.',
    );
  }

  static http.Response? _validateFileFields(
    Map<String, dynamic> b, {
    required bool requirePurpose,
  }) {
    if (requirePurpose) {
      final p = b['purpose'];
      if (p != 'attachment' && p != 'transcription' && p != 'content_job') {
        return _err(
          422,
          'invalid_purpose',
          'purpose must be attachment, transcription or content_job',
        );
      }
    }
    final filename = b['filename'];
    if (filename is! String || filename.trim().isEmpty) {
      return _err(
        422,
        'invalid_filename',
        'filename uses 1 to 255 characters without control characters or path separators',
      );
    }
    final size = b['size'];
    if (size is! int || size <= 0) {
      return _err(
        422,
        'invalid_size',
        'size is a positive number of bytes',
      );
    }
    final checksum = b['checksum'];
    if (checksum is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(checksum)) {
      return _err(
        422,
        'invalid_checksum',
        'checksum is the hexadecimal SHA-256 of the bytes',
      );
    }
    return null;
  }

  static http.Response _err(int status, String code, String message) {
    return http.Response(
      jsonEncode({'error': {'code': code, 'message': message}}),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}
