// A stateful Instant room server for tests, following annotations_api
// lib/presentation/rooms.rs and lib/domain/rooms.rs (annotations#44):
// ItemWrite {expected_revision, item} and RoomPatch {expected_revision,
// operation} with unknown fields refused, DELETE with If-Match, item revisions
// for ungrouped items, the room revision for room operations, groups and
// their members only through a room operation, no reuse of deleted ids, and
// the 409 bodies of the server. Several clients can share one server.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

typedef FakeJson = Map<String, Object?>;

final class FakeRoomServer {
  /// A room that expires 15 minutes from now unless [expiresAt] is given.
  FakeRoomServer({this.code = 'ROOM12', int? expiresAt, this.exists = true})
    : expiresAt =
          expiresAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900;

  final String code;
  final int expiresAt;

  /// False until a `PUT /instant/{code}` creates the room.
  bool exists;
  FakeJson page = {
    'width': 1000,
    'background': {'kind': 'blank'},
  };
  final items = <String, FakeJson>{};
  final itemRevisions = <String, int>{};
  int revision = 1;
  bool expired = false;

  /// Room files: metadata by id, and the bytes once uploaded.
  final fileMeta = <String, FakeJson>{};
  final fileBytes = <String, List<int>>{};
  bool failUploads = false;
  bool rejectItemWrites = false;
  bool offline = false;
  Future<void> Function()? beforeRoomGet;
  Future<void> Function()? beforeItemWrite;
  Future<void> Function()? beforeFileReservation;
  Future<void> Function()? beforeFileContent;
  final calls = <String>[];

  static const prefix = '/apps/annotations/v1';

  FakeJson roomJson() => {
    'code': code,
    'created_at': expiresAt - 900,
    'expires_at': expiresAt,
    'revision': revision,
    'schema_version': 1,
    'document': {
      'page': page,
      'items': [for (final it in items.values) _sorted(it)],
    },
    'item_revisions': itemRevisions,
    'max_file_bytes': 50000000,
    'max_ip_bytes': 50000000,
    'files': [
      for (final e in fileMeta.entries)
        if (fileBytes.containsKey(e.key)) {'id': e.key, ...e.value},
    ],
  };

  /// The server sends objects with sorted keys (serde_json without
  /// preserve_order), so clients must not compare key order.
  static Object? _sorted(Object? v) => switch (v) {
    final Map m => {
      for (final k in (m.keys.map((k) => '$k').toList()..sort()))
        k: _sorted(m[k]),
    },
    final List l => [for (final e in l) _sorted(e)],
    _ => v,
  };

  http.Client client() => MockClient(handle);

  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path.startsWith(prefix)
        ? req.url.path.substring(prefix.length)
        : req.url.path;
    calls.add('${req.method} $path');
    if (offline) throw http.ClientException('offline');
    if (!path.startsWith('/instant/$code')) return _err(404, 'not_found');
    if (expired) return _err(410, 'room_expired');
    final rest = path.substring('/instant/$code'.length);
    if (rest == '/files' && req.method == 'POST') {
      await beforeFileReservation?.call();
      final b = Map<String, Object?>.from(jsonDecode(req.body) as Map);
      if (_unknown(b, {'filename', 'content_type', 'size', 'checksum'})) {
        return _err(422, 'unknown_field');
      }
      final id = 'f${fileMeta.length + 1}';
      fileMeta[id] = {
        'filename': b['filename'],
        'content_type': b['content_type'],
        'size_bytes': b['size'],
        'preview': '${b['content_type']}'.startsWith('image/'),
      };
      return http.Response(jsonEncode({'id': id}), 200);
    }
    final content = RegExp(r'^/files/([^/]+)/content$').firstMatch(rest);
    if (content != null && req.method == 'PUT') {
      await beforeFileContent?.call();
      if (failUploads) return _err(500, 'storage_failed');
      fileBytes[content.group(1)!] = req.bodyBytes;
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    final file = RegExp(r'^/files/([^/]+)$').firstMatch(rest);
    if (file != null && req.method == 'GET') {
      final bytes = fileBytes[file.group(1)!];
      if (bytes == null) return _err(404, 'not_found');
      return http.Response.bytes(bytes, 200);
    }
    final body = req.body.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(req.body) as Map);

    if (rest.startsWith('/items') &&
        const {'POST', 'PUT', 'DELETE'}.contains(req.method)) {
      await beforeItemWrite?.call();
    }

    if (rest.isEmpty && req.method == 'PUT') {
      if (exists) return _err(409, 'room_exists');
      final b = Map<String, Object?>.from(jsonDecode(req.body) as Map);
      if (_unknown(b, {'schema_version', 'document'})) {
        return _err(422, 'unknown_field');
      }
      exists = true;
      revision = 0;
      final doc = Map<String, Object?>.from(b['document'] as Map);
      page = Map<String, Object?>.from(doc['page'] as Map);
      return _ok();
    }
    if (!exists) return _err(404, 'room_not_found');
    if (rest.isEmpty && req.method == 'GET') {
      await beforeRoomGet?.call();
      return _ok();
    }
    if (rest.isEmpty && req.method == 'PATCH') {
      if (_unknown(body, {'expected_revision', 'operation'})) {
        return _err(422, 'unknown_field');
      }
      if (body['expected_revision'] != revision) {
        return _err(409, 'room_revision_conflict');
      }
      return _apply(body['operation'] as Map, null);
    }
    if (rest == '/items' && req.method == 'POST') {
      if (rejectItemWrites) return _err(422, 'invalid_item');
      if (_unknown(body, {'expected_revision', 'item'})) {
        return _err(422, 'unknown_field');
      }
      final item = Map<String, Object?>.from(body['item'] as Map);
      return _target('${item['id']}', body['expected_revision'] as int, {
        'op': 'add',
        'item': item,
      });
    }
    final m = RegExp(r'^/items/([^/]+)$').firstMatch(rest);
    if (m != null) {
      final id = m.group(1)!;
      if (req.method == 'PUT') {
        if (rejectItemWrites) return _err(422, 'invalid_item');
        if (_unknown(body, {'expected_revision', 'item'})) {
          return _err(422, 'unknown_field');
        }
        return _target(id, body['expected_revision'] as int, {
          'op': 'replace',
          'item': body['item'],
        });
      }
      if (req.method == 'DELETE') {
        if (rejectItemWrites) return _err(422, 'invalid_item');
        final raw = req.headers['if-match'];
        if (raw == null) return _err(428, 'if_match_required');
        final rev = int.tryParse(raw.replaceAll('"', '').trim());
        if (rev == null || rev < 1) return _err(400, 'invalid_item_revision');
        return _target(id, rev, {'op': 'delete', 'id': id});
      }
    }
    return _err(404, 'not_found');
  }

  http.Response _target(String id, int expected, FakeJson op) {
    if ((itemRevisions[id] ?? 0) != expected ||
        (expected > 0 && !items.containsKey(id))) {
      return http.Response(
        jsonEncode({
          'error': 'item_revision_conflict',
          'message': 'The item changed; review the current item',
          'current_item': items[id] == null ? null : _sorted(items[id]),
          'item_revision': itemRevisions[id] ?? 0,
          'revision': revision,
        }),
        409,
      );
    }
    final kind = (op['item'] as Map?)?['kind'] ?? items[id]?['kind'];
    final inGroup = items.values.any(
      (it) =>
          it['kind'] == 'group' &&
          ((it['members'] as List?) ?? const []).contains(id),
    );
    if (kind == 'group' || inGroup) return _err(400, 'room_operation_required');
    return _apply(op, (id, expected));
  }

  http.Response _apply(Map op, (String, int)? target) {
    final before = {for (final e in items.entries) e.key: jsonEncode(e.value)};
    final steps = op['op'] == 'batch' ? op['steps'] as List : [op];
    final next = Map<String, FakeJson>.of(items);
    var nextPage = page;
    for (final raw in steps) {
      final s = raw as Map;
      switch (s['op']) {
        case 'add':
          final it = Map<String, Object?>.from(s['item'] as Map);
          final id = '${it['id']}';
          if (next.containsKey(id)) return _err(400, 'duplicate_id');
          if (itemRevisions.containsKey(id)) {
            return _err(409, 'item_id_reused');
          }
          next[id] = it;
        case 'replace':
          final it = Map<String, Object?>.from(s['item'] as Map);
          if (!next.containsKey('${it['id']}')) {
            return _err(400, 'missing_item');
          }
          next['${it['id']}'] = it;
        case 'delete':
          if (next.remove('${s['id']}') == null) {
            return _err(400, 'missing_item');
          }
        case 'page':
          nextPage = Map<String, Object?>.from(s['page'] as Map);
        default:
          return _err(400, 'invalid_operation');
      }
    }
    for (final id in {...before.keys, ...next.keys}) {
      final after = next[id] == null ? null : jsonEncode(next[id]);
      if (before[id] != after) {
        itemRevisions[id] = (itemRevisions[id] ?? 0) + 1;
      }
    }
    if (target != null) itemRevisions[target.$1] = target.$2 + 1;
    items
      ..clear()
      ..addAll(next);
    page = nextPage;
    revision++;
    return _ok();
  }

  static bool _unknown(FakeJson body, Set<String> allowed) =>
      body.keys.any((k) => !allowed.contains(k));

  http.Response _ok() => http.Response(jsonEncode(roomJson()), 200);

  static http.Response _err(int status, String code) =>
      http.Response(jsonEncode({'error': code, 'message': code}), status);
}
