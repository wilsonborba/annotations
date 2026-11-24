/// One open Instant room page (annotations#44): opens the room by its code
/// (reads it, or creates it when the code is free), puts the room document
/// in the shared paper editor and shares it through [RoomShare]. The view
/// listens to it for the remaining time, the sharing state, refused changes
/// and the expiry. Zoom, view lock, Focus, toolbar and editing mode live in
/// the editor of this person only (C1.9); only the document is shared.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../dal/remote/api_adapter.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/instant_room_files.dart';
import '../../../domain/services/instant_room_service.dart';
import '../../../domain/services/instant_room_share.dart';
import '../../../domain/services/instant_room_sync.dart';
import 'paper_handler.dart';
import 'text_handler.dart';

/// The paper editor as the room share sees it.
final class _PaperRoomEditor implements RoomEditor {
  _PaperRoomEditor(this.paper, this.owner);
  final PaperHandler paper;
  final InstantRoomHandler owner;

  @override
  InstantRoomDocument get document => paper.document as InstantRoomDocument;

  @override
  bool get busy => paper.holding || paper.activeInk.value != null;

  @override
  bool receive(InstantRoomDocument document) {
    if (paper.holding || paper.activeInk.value != null) return false;
    final text = owner.text;
    if (InstantRoomHandler.changesOpenBlock(
      paper.document,
      document,
      text?.editing,
    )) {
      // The open block still holds the local text; it closes so the next
      // keystroke cannot write it over the room version (C1.5).
      text!.end();
    }
    return paper.receive(document);
  }
}

class InstantRoomHandler extends ChangeNotifier {
  InstantRoomHandler(
    this.api,
    this.code, {
    required this.readPath,
    this.settings = const RoomShareSettings(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ApiAdapter api;
  final String code;
  final Future<Uint8List> Function(String path) readPath;
  final RoomShareSettings settings;
  final DateTime Function() _clock;

  bool opening = true;

  /// A failure to open the room, shown with Try again.
  Object? error;

  InstantRoomService? room;
  RoomShare? share;
  PaperHandler? paper;

  /// The text flow of the editor; the page sets it with the editor.
  TextHandler? text;

  /// True when [next] changes the item [openId] that is open for typing.
  static bool changesOpenBlock(
    NoteDocument current,
    NoteDocument next,
    String? openId,
  ) {
    if (openId == null) return false;
    Object? item(NoteDocument d) => [
      for (final it in (d.toJson()['items'] as List?) ?? const [])
        if ((it as Map)['id'] == openId) it,
    ].firstOrNull;
    return !InstantRoomSync.same(item(current), item(next));
  }

  Timer? _tick;
  bool _closed = false;

  static final _empty = <String, Object?>{
    'page': {
      'width': 1000,
      'background': {'kind': 'blank'},
    },
    'items': <Object?>[],
  };

  /// Reads the room; a free code creates it (`PUT`), and a code taken in
  /// the meantime is read again. A gone room shows as expired.
  Future<void> open() async {
    opening = true;
    error = null;
    _emit();
    final service = InstantRoomService(api);
    try {
      try {
        await service.joinRoom(code);
      } on ApiError catch (e) {
        if (e.status != 404) rethrow;
        try {
          await service.createRoom(code: code, document: _empty);
        } on ApiError catch (taken) {
          if (taken.status != 409) rethrow;
          await service.joinRoom(code);
        }
      }
    } on Object catch (e) {
      if (service.state != InstantSharingState.expired) {
        error = e;
        opening = false;
        _emit();
        return;
      }
    }
    if (_closed) return;
    room = service;
    if (service.state != InstantSharingState.expired) _start(service);
    opening = false;
    _emit();
  }

  void _start(InstantRoomService service) {
    final files = RoomFiles(service, readPath: readPath);
    final share = RoomShare(
      service,
      files: files,
      settings: settings,
      clock: _clock,
    );
    final paper = PaperHandler(
      noteId: 'instant-$code',
      document: RoomShare.documentOf(service.document),
      autosave: share,
    );
    share.attach(_PaperRoomEditor(paper, this));
    share.sharing.addListener(_emit);
    share.conflicts.addListener(_emit);
    this.share = share;
    this.paper = paper;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _emit());
  }

  /// True once the fixed lifetime is over (C1.7).
  bool get expired =>
      room?.state == InstantSharingState.expired ||
      share?.sharing.value == InstantSharingState.expired;

  InstantSharingState get sharing =>
      share?.sharing.value ?? InstantSharingState.connecting;

  Duration get remaining => share?.remaining ?? Duration.zero;

  bool get nearExpiry => share?.nearExpiry ?? false;

  List<RoomConflict> get conflicts => share?.conflicts.value ?? const [];

  /// After a lost connection: read the room, then share the kept change.
  Future<void> retry() async => share?.retry();

  void dismissConflicts() => share?.dismissConflicts();

  void _emit() {
    if (expired) _tick?.cancel();
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _tick?.cancel();
    final share = this.share;
    share?.sharing.removeListener(_emit);
    share?.conflicts.removeListener(_emit);
    // A change still in its pause is shared before the share stops.
    share?.flush().whenComplete(share.dispose);
    paper?.dispose();
    super.dispose();
  }
}
