/// The files of an open Instant room for the editor (annotations#44, C1.7,
/// C1.8). A new file goes in two steps: the reservation
/// (`POST /instant/{code}/files`) and the bytes
/// (`PUT /instant/{code}/files/{id}/content`); a failed upload is never
/// shown as ready. Bytes come from `GET /instant/{code}/files/{id}` until the
/// room expires; at the expiry the kept bytes are dropped and nothing more
/// is downloaded.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../dal/remote/api_adapter.dart';
import '../models/local_note.dart';
import 'editor_files.dart';
import 'instant_room_service.dart';

final class RoomFiles implements EditorFiles {
  RoomFiles(this.room, {required this.readPath});

  final InstantRoomService room;

  /// Reads a picked or dropped file of this device.
  final Future<Uint8List> Function(String path) readPath;

  final _bytes = <String, Uint8List>{};

  bool get _open => room.state != InstantSharingState.expired;

  @override
  Future<LocalAttachment> importFile(
    String sourcePath, {
    required String type,
  }) async {
    if (!room.canEdit) {
      throw StateError('Cannot upload while room is ${room.state}');
    }
    final bytes = await readPath(sourcePath);
    if (!room.canEdit) {
      throw StateError('Cannot upload while room is ${room.state}');
    }
    return importBytes(
      bytes,
      name: sourcePath.split(RegExp(r'[\\/]')).last,
      type: type,
    );
  }

  @override
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  }) async {
    final file = await room.uploadFile(
      name: name,
      contentType: type,
      sizeBytes: bytes.length,
      bytes: bytes,
      uploadBytes: (id) async {
        final req =
            http.Request(
                'PUT',
                Uri.parse(
                  '${room.api.base}/instant/${room.roomCode}/files/$id/content',
                ),
              )
              ..headers['content-type'] = type
              ..bodyBytes = bytes;
        final resp = await http.Response.fromStream(
          await room.api.client.send(req),
        );
        if (resp.statusCode >= 400) {
          throw ApiError(resp.statusCode, 'upload_failed');
        }
      },
    );
    _bytes[file.fileId] = bytes;
    return LocalAttachment(
      id: file.fileId,
      name: name,
      type: type,
      size: bytes.length,
      path: '',
    );
  }

  @override
  Future<LocalAttachment?> attachment(String id) async {
    if (!_open) return null;
    final meta = room.roomFiles[id];
    if (meta != null) {
      return LocalAttachment(
        id: id,
        name: '${meta['filename'] ?? id}',
        type: '${meta['content_type'] ?? 'application/octet-stream'}',
        size: (meta['size_bytes'] as num?)?.toInt() ?? 0,
        path: '',
      );
    }
    for (final f in room.files) {
      if (f.fileId == id && f.ready) {
        return LocalAttachment(
          id: id,
          name: f.name,
          type: 'application/octet-stream',
          size: f.sizeBytes,
          path: '',
        );
      }
    }
    return null;
  }

  @override
  Future<Uint8List?> readAttachment(String id) async {
    if (!_open) return null;
    final kept = _bytes[id];
    if (kept != null) return kept;
    final code = room.roomCode;
    if (code == null) return null;
    final resp = await room.api.client.get(
      Uri.parse('${room.api.base}/instant/$code/files/$id'),
    );
    if (resp.statusCode == 410) {
      room.expire();
      return null;
    }
    if (resp.statusCode >= 400 || !_open) return null;
    return _bytes[id] = resp.bodyBytes;
  }

  /// A fresh upload stays in the room until it expires; nothing to undo.
  @override
  Future<void> discardAttachment(String id) async {}

  /// Drops every kept byte, at the expiry.
  void clear() => _bytes.clear();
}
