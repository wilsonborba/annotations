import 'package:crypto/crypto.dart';

import '../../dal/remote/api_adapter.dart';

enum InstantSharingState {
  connecting,
  sharing,
  shared,
  connectionLost,
  expired,
}

final class InstantRuleError implements Exception {
  final String code;
  final String message;

  const InstantRuleError(this.code, this.message);

  @override
  String toString() => '$code: $message';
}

final class InstantConflictDraft {
  final String itemId;
  final int attemptedRevision;
  final String? keptText;
  final Map<String, Object?> rejectedPayload;

  const InstantConflictDraft({
    required this.itemId,
    required this.attemptedRevision,
    required this.keptText,
    required this.rejectedPayload,
  });
}

final class InstantUploadAllowance {
  final int maxFileBytes;
  final int usedBytes;
  final int maxTotalBytes;

  const InstantUploadAllowance({
    required this.maxFileBytes,
    required this.usedBytes,
    required this.maxTotalBytes,
  });

  int get remainingBytes =>
      maxTotalBytes > usedBytes ? maxTotalBytes - usedBytes : 0;

  bool canUpload(int sizeBytes) =>
      sizeBytes <= maxFileBytes && sizeBytes <= remainingBytes;
}

final class InstantUploadedFile {
  final String fileId;
  final String name;
  final int sizeBytes;
  final bool ready;

  const InstantUploadedFile({
    required this.fileId,
    required this.name,
    required this.sizeBytes,
    required this.ready,
  });
}

/// Client-side Instant room adapter and state machine (annotations#43).
/// No login, no history, fixed expiry with no extension or Note conversion.
class InstantRoomService {
  final ApiAdapter api;
  String? roomCode;
  DateTime? expiresAt;
  InstantSharingState state = InstantSharingState.connecting;

  final Map<String, Map<String, Object?>> items = {};
  final Map<String, int> itemRevisions = {};
  final List<InstantConflictDraft> conflicts = [];
  final List<Map<String, Object?>> pendingEdits = [];
  final List<InstantUploadedFile> files = [];

  InstantUploadAllowance allowance = const InstantUploadAllowance(
    maxFileBytes: 10 * 1024 * 1024,
    usedBytes: 0,
    maxTotalBytes: 50 * 1024 * 1024,
  );

  bool get hasHistory => false;
  bool get canExtend => false;
  bool get canConvertToNote => false;
  bool get canEdit =>
      state == InstantSharingState.sharing ||
      state == InstantSharingState.shared;

  InstantRoomService(this.api);

  /// Encodes integer coordinate/dimension fields as true integers so web Dart
  /// never sends fractional floats where the server expects integers (#20/#43).
  static Map<String, Object?> normalizeIntegerFields(
    Map<String, Object?> item,
  ) {
    const intKeys = {'x', 'y', 'width', 'height', 'level', 'revision', 'size'};
    final out = Map<String, Object?>.from(item);
    for (final k in intKeys) {
      final v = out[k];
      if (v is num) out[k] = v.toInt();
    }
    return out;
  }

  int revision = 0;

  Future<void> createRoom({
    String code = 'ROOM12',
    int schemaVersion = 1,
    Map<String, Object?>? document,
  }) async {
    state = InstantSharingState.connecting;
    final resp = await api.request(
      '/instant/$code',
      method: 'PUT',
      body: {
        'schema_version': schemaVersion,
        'document':
            document ??
            const {
              'page': {
                'width': 1000,
                'background': {'kind': 'blank'},
              },
              'items': [],
            },
      },
    );
    _applyRoomState(resp);
    state = InstantSharingState.shared;
  }

  Future<void> joinRoom(String codeOrLink) async {
    final code = _extractCode(codeOrLink);
    state = InstantSharingState.connecting;
    try {
      final resp = await api.request('/instant/$code', method: 'GET');
      _applyRoomState(resp);
      state = InstantSharingState.shared;
    } on ApiError catch (err) {
      if (err.status == 410) {
        expire();
        return;
      }
      state = InstantSharingState.connectionLost;
      rethrow;
    }
  }

  static String _extractCode(String codeOrLink) {
    final trimmed = codeOrLink.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return trimmed;
  }

  void _applyRoomState(Map<String, dynamic> resp) {
    roomCode = '${resp['code'] ?? roomCode ?? ''}';
    if (resp['revision'] is num) {
      revision = (resp['revision'] as num).toInt();
    }
    final rawExp = resp['expires_at'];
    if (rawExp is num) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(
        rawExp.toInt() * 1000,
        isUtc: true,
      );
    } else if (rawExp is String) {
      expiresAt = DateTime.tryParse(rawExp);
    }
    final doc = resp['document'];
    final rawItems =
        (doc is Map ? doc['items'] as List? : null) ??
        (resp['items'] as List?) ??
        const [];
    final revMap = (resp['item_revisions'] as Map?) ?? const {};
    items.clear();
    itemRevisions.clear();
    for (final raw in rawItems) {
      final map = Map<String, Object?>.from(raw as Map);
      final id = '${map['id']}';
      items[id] = map;
      final r = revMap[id] ?? map['item_revision'];
      itemRevisions[id] = (r as num?)?.toInt() ?? 1;
    }
    if (resp['max_file_bytes'] is num || resp['max_ip_bytes'] is num) {
      allowance = InstantUploadAllowance(
        maxFileBytes:
            (resp['max_file_bytes'] as num?)?.toInt() ?? allowance.maxFileBytes,
        usedBytes: allowance.usedBytes,
        maxTotalBytes:
            (resp['max_ip_bytes'] as num?)?.toInt() ?? allowance.maxTotalBytes,
      );
    } else if (resp['allowance'] is Map) {
      final a = Map<String, dynamic>.from(resp['allowance'] as Map);
      allowance = InstantUploadAllowance(
        maxFileBytes:
            (a['max_file_bytes'] as num?)?.toInt() ?? allowance.maxFileBytes,
        usedBytes: (a['used_bytes'] as num?)?.toInt() ?? 0,
        maxTotalBytes:
            (a['max_total_bytes'] as num?)?.toInt() ?? allowance.maxTotalBytes,
      );
    }
  }

  void markDisconnected() {
    if (state == InstantSharingState.expired) return;
    state = InstantSharingState.connectionLost;
  }

  /// Stops edits, sharing, uploads and downloads and clears temporary content.
  void expire() {
    state = InstantSharingState.expired;
    items.clear();
    itemRevisions.clear();
    pendingEdits.clear();
    conflicts.clear();
    files.clear();
  }

  /// Commits a completed item edit (never called during an unfinished gesture).
  Future<bool> sendCompletedEdit(
    Map<String, Object?> rawItem, {
    bool isGestureInProgress = false,
  }) async {
    if (isGestureInProgress || !canEdit || roomCode == null) {
      if (state == InstantSharingState.connectionLost) {
        pendingEdits.add(rawItem);
      }
      return false;
    }

    final item = normalizeIntegerFields(rawItem);
    final id = '${item['id']}';
    final expectedRev = itemRevisions[id] ?? 0;
    final isNew = expectedRev == 0;

    state = InstantSharingState.sharing;
    try {
      final resp = await api.request(
        isNew ? '/instant/$roomCode/items' : '/instant/$roomCode/items/$id',
        method: isNew ? 'POST' : 'PUT',
        body: {'expected_revision': expectedRev, 'item': item},
      );
      if (resp['document'] is Map || resp['item_revisions'] is Map) {
        _applyRoomState(resp);
      } else {
        items[id] = item;
        itemRevisions[id] =
            (resp['item_revision'] as num?)?.toInt() ?? (expectedRev + 1);
      }
      state = InstantSharingState.shared;
      return true;
    } on ApiError catch (err) {
      if (err.status == 410) {
        expire();
        return false;
      }
      if (err.status == 409) {
        final spans = item['spans'] as List?;
        final keptText = spans == null
            ? item['text'] as String?
            : spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join();
        conflicts.add(
          InstantConflictDraft(
            itemId: id,
            attemptedRevision: expectedRev,
            keptText: keptText,
            rejectedPayload: item,
          ),
        );
        final details = err.details;
        if (details != null && details['current_item'] is Map) {
          items[id] = Map<String, Object?>.from(details['current_item'] as Map);
          if (details['item_revision'] is num) {
            itemRevisions[id] = (details['item_revision'] as num).toInt();
          }
          if (details['revision'] is num) {
            revision = (details['revision'] as num).toInt();
          }
          state = InstantSharingState.shared;
        } else {
          // Refresh from server state before any retry (no blind replay).
          await joinRoom(roomCode!);
        }
        return false;
      }
      if (err.status == 400 || err.status == 422) {
        state = InstantSharingState.shared;
        throw InstantRuleError('rule_rejected', err.message);
      }
      state = InstantSharingState.connectionLost;
      pendingEdits.add(item);
      rethrow;
    }
  }

  /// Two-stage upload: reserves via `POST /instant/{code}/files`, then uploads
  /// raw bytes via [uploadBytes] (to `PUT /instant/{code}/files/{id}/content`).
  /// Failed uploads are never marked ready.
  Future<InstantUploadedFile> uploadFile({
    required String name,
    String contentType = 'application/octet-stream',
    required int sizeBytes,
    required Future<void> Function(String uploadId) uploadBytes,
    String? checksum,
    List<int>? bytes,
  }) async {
    if (!canEdit || roomCode == null) {
      throw StateError('Cannot upload while room is $state');
    }
    if (!allowance.canUpload(sizeBytes)) {
      throw const InstantRuleError(
        'allowance_exceeded',
        'File exceeds single-file limit or room allowance.',
      );
    }

    final resolvedChecksum =
        checksum ?? sha256.convert(bytes ?? const <int>[]).toString();
    final staged = await api.request(
      '/instant/$roomCode/files',
      method: 'POST',
      body: {
        'filename': name,
        'content_type': contentType,
        'size': sizeBytes,
        'checksum': resolvedChecksum,
      },
    );
    final fileId = '${staged['id'] ?? staged['file_id']}';
    try {
      await uploadBytes(fileId);
      final uploaded = InstantUploadedFile(
        fileId: fileId,
        name: name,
        sizeBytes: sizeBytes,
        ready: true,
      );
      files.add(uploaded);
      allowance = InstantUploadAllowance(
        maxFileBytes: allowance.maxFileBytes,
        usedBytes: allowance.usedBytes + sizeBytes,
        maxTotalBytes: allowance.maxTotalBytes,
      );
      return uploaded;
    } catch (_) {
      // Never leave a failed upload looking ready.
      files.add(
        InstantUploadedFile(
          fileId: fileId,
          name: name,
          sizeBytes: sizeBytes,
          ready: false,
        ),
      );
      rethrow;
    }
  }
}
