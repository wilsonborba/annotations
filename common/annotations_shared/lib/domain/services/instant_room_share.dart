/// The sharing of one open Instant room (annotations#44, C1.1 to C1.7).
///
/// It is the [PaperSaver] of the room editor: an accepted edit is shared
/// after a short pause (text) or when its gesture ended (drawings, moves),
/// never while a gesture still holds the page. It reads the room again at a
/// fixed interval and shows the accepted changes of other people on top of
/// the local changes that are not shared yet. At the fixed expiry it stops
/// sharing and clears the content (C1.7). Nothing here undoes or extends.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/local_note.dart';
import '../models/note_document.dart';
import 'editor_files.dart';
import 'instant_room_files.dart';
import 'instant_room_service.dart';
import 'instant_room_sync.dart';
import 'note_autosave.dart';

/// Timings of room sharing. The records leave the exact values to the
/// implementation (C1.1, C1.3).
final class RoomShareSettings {
  const RoomShareSettings({
    this.pause = const Duration(milliseconds: 700),
    this.poll = const Duration(seconds: 2),
    this.warning = const Duration(minutes: 2),
  });

  /// The pause after an edit before it is shared.
  final Duration pause;

  /// How often the room is read for changes of other people.
  final Duration poll;

  /// How long before the expiry the warning shows.
  final Duration warning;
}

/// The local side of the editor that the share works with.
abstract interface class RoomEditor {
  /// The current local document.
  InstantRoomDocument get document;

  /// True while a gesture holds the page or a stroke is drawn.
  bool get busy;

  /// Shows [document]; false when the editor is busy (try again later).
  bool receive(InstantRoomDocument document);
}

final class RoomShare implements PaperSaver {
  RoomShare(
    this.room, {
    required this.files,
    this.settings = const RoomShareSettings(),
    DateTime Function()? clock,
  }) : sync = InstantRoomSync(room),
       _clock = clock ?? DateTime.now;

  final InstantRoomService room;
  final InstantRoomSync sync;
  final RoomShareSettings settings;
  final DateTime Function() _clock;

  @override
  final EditorFiles files;

  /// Connecting, Sharing, Shared, Connection lost or Expired (C1.4, C1.7).
  final sharing = ValueNotifier(InstantSharingState.connecting);

  /// Refused local changes kept for review (C1.5); the page lists them.
  final conflicts = ValueNotifier<List<RoomConflict>>(const []);

  /// The page indicator of the editor. Instant shows [sharing] instead.
  @override
  final ValueNotifier<SaveState> state = ValueNotifier(SaveState.saved);

  RoomEditor? _editor;
  Json? _pending;
  Timer? _pause, _poll, _expiry;
  Future<void>? _running;
  bool _disposed = false;

  static final _schema = DocumentSchema(DocumentFamily.instant.schemaName, 1);

  /// The room document as an editor document.
  static InstantRoomDocument documentOf(Json json) =>
      NoteDocument.fromJson(json, schema: _schema) as InstantRoomDocument;

  /// Starts sharing for [editor]: the room must be joined or created.
  void attach(RoomEditor editor) {
    _editor = editor;
    _set(room.state);
    _poll = Timer.periodic(settings.poll, (_) => _tick());
    final end = room.expiresAt;
    if (end != null) {
      _expiry = Timer(end.difference(_clock()), _expire);
    }
  }

  /// The time left before the fixed expiry (C1.1), never below zero.
  Duration get remaining {
    final end = room.expiresAt;
    if (end == null) return Duration.zero;
    final left = end.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// True from [RoomShareSettings.warning] before the expiry.
  bool get nearExpiry =>
      room.expiresAt != null && remaining <= settings.warning;

  @override
  void edited(LocalNoteDraft note) {
    if (!room.canEdit && room.state != InstantSharingState.connectionLost) {
      return;
    }
    _pending = note.document.toJson();
    state.value = SaveState.saving;
    _schedule();
  }

  void _schedule() {
    _pause?.cancel();
    _pause = Timer(settings.pause, () {
      _pause = null;
      _start();
    });
  }

  Future<void> _start() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<void> _drain() async {
    while (_pending != null && _pause == null && !_disposed) {
      final editor = _editor;
      if (editor != null && editor.busy) {
        _schedule();
        return;
      }
      if (room.state == InstantSharingState.connectionLost) {
        state.value = SaveState.failed;
        return;
      }
      final local = _pending!;
      _pending = null;
      _set(InstantSharingState.sharing);
      try {
        final clean = await sync.push(local);
        if (!clean) conflicts.value = List.of(sync.conflicts);
        _show();
        state.value = _pending == null ? SaveState.saved : SaveState.saving;
      } on Object {
        if (room.state == InstantSharingState.expired) {
          _expire();
          return;
        }
        // Keep the change while the editor stays open (C1.6).
        _pending ??= local;
        state.value = SaveState.failed;
      }
      _set(room.state);
    }
  }

  /// Shows the current room with the unshared local changes on top.
  void _show() {
    final editor = _editor;
    if (editor == null) return;
    final next = sync.rebase(editor.document.toJson());
    if (!InstantRoomSync.same(next, editor.document.toJson())) {
      editor.receive(documentOf(next));
    }
  }

  Future<void> _tick() async {
    if (_disposed || _running != null || _pending != null) return;
    if (_editor?.busy ?? false) return;
    final before = room.revision;
    try {
      await room.refresh();
    } on Object {
      _set(room.state);
      if (room.state == InstantSharingState.expired) _expire();
      return;
    }
    if (room.state == InstantSharingState.expired) return _expire();
    if (room.revision != before) _show();
    _set(room.state);
  }

  /// After a lost connection: read the room first, show it with the kept
  /// changes on top, and only then share them again (C1.6).
  @override
  Future<void> retry() async {
    try {
      await room.refresh();
    } on Object {
      _set(room.state);
      return;
    }
    if (room.state == InstantSharingState.expired) return _expire();
    _show();
    _set(room.state);
    if (_pending != null) {
      _pending = _editor?.document.toJson() ?? _pending;
      await _start();
    }
  }

  @override
  Future<void> flush() async {
    _pause?.cancel();
    _pause = null;
    await _running;
    if (_pending != null) await _start();
  }

  /// Forgets the refused changes after the person reviewed them.
  void dismissConflicts() {
    sync.conflicts.clear();
    conflicts.value = const [];
  }

  void _expire() {
    if (_disposed) return;
    room.expire();
    _pending = null;
    _pause?.cancel();
    _poll?.cancel();
    _expiry?.cancel();
    sync.conflicts.clear();
    conflicts.value = const [];
    if (files case final RoomFiles roomFiles) roomFiles.clear();
    _editor?.receive(documentOf(room.document));
    _set(InstantSharingState.expired);
  }

  void _set(InstantSharingState value) {
    if (!_disposed) sharing.value = value;
  }

  @override
  void dispose() {
    _disposed = true;
    _pause?.cancel();
    _poll?.cancel();
    _expiry?.cancel();
    sharing.dispose();
    conflicts.dispose();
    state.dispose();
  }
}
