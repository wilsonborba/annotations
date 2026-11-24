import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/local_note.dart';
import 'local_note_store.dart';

/// Read-only access to files referenced by the currently published note view.
/// The API checks both [noteId] and [view] against the published revision, so
/// private, unpublished, and unrelated files remain inaccessible.
final class ReadOnlyNoteStore implements LocalNoteStore {
  ReadOnlyNoteStore({this.noteId, this.view, this.apiBase, this.client});

  final String? noteId;
  final String? view;
  final String? apiBase;
  final http.Client? client;

  final _media = <String, Future<_PublicMedia?>>{};

  @override
  Future<LocalAttachment?> attachment(String id) async =>
      (await _readMedia(id))?.attachment;

  @override
  Future<Uint8List?> readAttachment(String id) async =>
      (await _readMedia(id))?.bytes;

  Future<_PublicMedia?> _readMedia(String fileId) =>
      _media.putIfAbsent(fileId, () => _fetchMedia(fileId));

  Future<_PublicMedia?> _fetchMedia(String fileId) async {
    final noteId = this.noteId;
    final view = this.view;
    final apiBase = this.apiBase;
    final client = this.client;
    if (noteId == null || view == null || apiBase == null || client == null) {
      throw UnsupportedError('Published media context is required.');
    }

    final uri = Uri.parse(
      '${apiBase.replaceFirst(RegExp(r'/$'), '')}/media/${Uri.encodeComponent(fileId)}',
    ).replace(queryParameters: {'note_id': noteId, 'view': view});
    final response = await client.get(uri);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'Published media request failed (${response.statusCode}).',
        uri,
      );
    }

    final bytes = response.bodyBytes;
    final type = response.headers['content-type'] ?? 'application/octet-stream';
    final name = _publicFileName(
      response.headers['content-disposition'],
      fallback: fileId,
    );
    return _PublicMedia(
      LocalAttachment(
        id: fileId,
        name: name,
        type: type.split(';').first.trim(),
        size: bytes.length,
        path: '',
      ),
      bytes,
    );
  }

  static String _publicFileName(
    String? disposition, {
    required String fallback,
  }) {
    if (disposition == null) return fallback;
    final encoded = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(disposition)?.group(1);
    if (encoded != null) {
      try {
        return Uri.decodeComponent(encoded);
      } on FormatException {
        return fallback;
      }
    }
    final quoted = RegExp(r'filename="([^"]*)"').firstMatch(disposition);
    return quoted?.group(1) ?? fallback;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('The public reader does not save notes.');
}

final class _PublicMedia {
  const _PublicMedia(this.attachment, this.bytes);

  final LocalAttachment attachment;
  final Uint8List bytes;
}
