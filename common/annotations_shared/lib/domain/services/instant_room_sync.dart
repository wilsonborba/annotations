/// Shares the edits of one open Instant room (annotations#44, C1.3 to C1.6).
///
/// The editor keeps the local document. [InstantRoomService] mirrors the room
/// as the server last accepted it. The sync keeps a base: the room state the
/// local document was last built on, with its item and room revisions.
///
/// [push] sends what changed locally since the base, with the base revisions,
/// so the server refuses a change to an item that someone else changed first
/// (C1.5): nothing is overwritten silently. An ungrouped item goes by itself,
/// so people can edit different blocks at the same time; a group, a group
/// member or the page goes as one room operation, as the server requires.
/// [rebase] then puts the local changes that are not shared yet on top of the
/// current room, and refused items take the room version; their text is kept
/// in [conflicts] to review or copy. Nothing refused is replayed.
library;

import '../../dal/remote/api_adapter.dart';
import 'instant_room_service.dart';

typedef Json = Map<String, Object?>;

/// The writes from one room document to another.
final class RoomChanges {
  const RoomChanges({
    this.added = const [],
    this.replaced = const [],
    this.deleted = const [],
    this.page,
    this.needsRoomOperation = false,
  });

  final List<Json> added, replaced;
  final List<String> deleted;
  final Json? page;

  /// True when a group, a group member or the page changes: then all the
  /// changes go as one batch room operation.
  final bool needsRoomOperation;

  bool get isEmpty =>
      added.isEmpty && replaced.isEmpty && deleted.isEmpty && page == null;

  Set<String> get ids => {
    for (final it in added) '${it['id']}',
    for (final it in replaced) '${it['id']}',
    ...deleted,
  };

  /// The batch operation for `PATCH /instant/{code}`.
  Json get operation => {
    'op': 'batch',
    'steps': [
      for (final it in added) {'op': 'add', 'item': it},
      for (final it in replaced) {'op': 'replace', 'item': it},
      for (final id in deleted) {'op': 'delete', 'id': id},
      if (page != null) {'op': 'page', 'page': page},
    ],
  };
}

/// One local change that the server refused because someone changed the
/// same item first. [text] is the refused text, kept to review or copy.
final class RoomConflict {
  const RoomConflict(this.itemId, this.text);
  final String itemId;
  final String? text;
}

typedef _Base = ({Json document, Map<String, int> items, int revision});

final class InstantRoomSync {
  /// Starts from the room as [room] holds it now.
  InstantRoomSync(this.room) : _base = _snapshot(room);

  final InstantRoomService room;

  /// Refused local changes, oldest first, until the person dismisses them.
  final conflicts = <RoomConflict>[];

  _Base _base;
  final _refused = <String>{};
  bool _refusedPage = false;

  /// The room document the local document is built on.
  Json get base => _base.document;

  /// The writes from [from] to [to].
  static RoomChanges diff(Json from, Json to) {
    final before = _byId(from), after = _byId(to);
    final grouped = {..._grouped(before.values), ..._grouped(after.values)};
    final added = <Json>[], replaced = <Json>[], deleted = <String>[];
    for (final MapEntry(key: id, value: it) in after.entries) {
      final old = before[id];
      if (old == null) {
        added.add(it);
      } else if (!same(old, it)) {
        replaced.add(it);
      }
    }
    for (final id in before.keys) {
      if (!after.containsKey(id)) deleted.add(id);
    }
    final page = same(from['page'], to['page'])
        ? null
        : Map<String, Object?>.from(to['page'] as Map);
    final changes = RoomChanges(
      added: added,
      replaced: replaced,
      deleted: deleted,
      page: page,
    );
    return RoomChanges(
      added: added,
      replaced: replaced,
      deleted: deleted,
      page: page,
      needsRoomOperation: page != null || changes.ids.any(grouped.contains),
    );
  }

  /// Sends the local changes since the base. Returns false when the server
  /// refused some of them (see [conflicts]). Call [rebase] after it. A lost
  /// connection or an expired room rethrows the error.
  Future<bool> push(Json local) async {
    final changes = diff(_base.document, local);
    if (changes.isEmpty) return true;
    if (changes.needsRoomOperation) return _roomOperation(local, changes);
    var clean = true;
    for (final it in [...changes.added, ...changes.replaced]) {
      final id = '${it['id']}';
      clean &= await _item(
        it,
        () => room.writeItem(it, expected: _base.items[id] ?? 0),
      );
    }
    for (final id in changes.deleted) {
      clean &= await _item({
        'id': id,
      }, () => room.deleteItem(id, expected: _base.items[id] ?? 0));
    }
    return clean;
  }

  /// A room operation made on the base room revision is refused whenever the
  /// room moved, also for edits of other items. When none of the items or
  /// the page it touches changed on the server since the base, it is sent
  /// once more on the current room; otherwise it is a real conflict.
  Future<bool> _roomOperation(Json local, RoomChanges changes) async {
    try {
      await room.patchRoom(changes.operation, expected: _base.revision);
      return true;
    } on ApiError catch (err) {
      if (err.status != 409) rethrow;
    }
    await room.refresh();
    final theirs = diff(_base.document, room.document);
    final overlap =
        theirs.ids.any(changes.ids.contains) ||
        (theirs.page != null && changes.page != null);
    if (!overlap) {
      final again = diff(room.document, _merge(local, const {}));
      try {
        await room.patchRoom(again.operation, expected: room.revision);
        return true;
      } on ApiError catch (err) {
        if (err.status != 409) rethrow;
        await room.refresh();
      }
    }
    _refuse([...changes.added, ...changes.replaced]);
    _refused.addAll(changes.deleted);
    _refusedPage = changes.page != null;
    return false;
  }

  Future<bool> _item(Json it, Future<void> Function() write) async {
    try {
      await write();
      return true;
    } on ApiError catch (err) {
      if (err.status != 409) rethrow;
      _refuse([it]);
      return false;
    }
  }

  void _refuse(List<Json> items) {
    for (final it in items) {
      _refused.add('${it['id']}');
      final text = _text(it);
      if (text != null && text.isNotEmpty) {
        conflicts.add(RoomConflict('${it['id']}', text));
      }
    }
  }

  /// The local document on top of the current room: what changed locally
  /// since the base and was not refused keeps the local version, everything
  /// else takes the room version. Room order first, then local additions.
  /// The room becomes the new base.
  Json rebase(Json local) {
    final out = _merge(local, _refused);
    _refused.clear();
    _refusedPage = false;
    _base = _snapshot(room);
    return out;
  }

  Json _merge(Json local, Set<String> refused) {
    final base = _byId(_base.document);
    final mine = _byId(local);
    final server = _byId(room.document);
    bool keepMine(String id) =>
        !refused.contains(id) && !same(base[id], mine[id]);
    final items = <Json>[];
    for (final MapEntry(key: id, value: it) in server.entries) {
      if (!keepMine(id)) {
        items.add(it);
      } else if (mine[id] case final Json local?) {
        items.add(local);
      }
    }
    for (final MapEntry(key: id, value: it) in mine.entries) {
      if (!server.containsKey(id) && !base.containsKey(id) && keepMine(id)) {
        items.add(it);
      }
    }
    final pageHere =
        !_refusedPage && !same(_base.document['page'], local['page']);
    return {'page': pageHere ? local['page'] : room.page, 'items': items};
  }

  static _Base _snapshot(InstantRoomService room) => (
    document: room.document,
    items: Map.of(room.itemRevisions),
    revision: room.revision,
  );

  static Map<String, Json> _byId(Json doc) => {
    for (final raw in (doc['items'] as List?) ?? const [])
      '${(raw as Map)['id']}': Map<String, Object?>.from(raw),
  };

  static Set<String> _grouped(Iterable<Json> items) => {
    for (final it in items)
      if (it['kind'] == 'group') ...[
        '${it['id']}',
        for (final m in (it['members'] as List?) ?? const []) '$m',
      ],
  };

  /// Structural JSON equality: key order does not count (the server sends
  /// sorted keys) and 38 equals 38.0.
  static bool same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && same(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!same(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static String? _text(Json it) => switch (it['spans']) {
    final List spans =>
      spans.map((s) => s is Map ? '${s['text'] ?? ''}' : '$s').join(),
    _ => it['text'] as String?,
  };
}
