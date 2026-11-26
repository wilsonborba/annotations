/// Autosave of one open local note (B1.2, D2.3).
///
/// Every edit hands over the complete note. After a short pause without
/// edits the latest version goes to the store; edits in the pause join one
/// save. The state is [SaveState.saving] while any edit is not committed,
/// [SaveState.saved] only after the store commit of the latest edit, and
/// [SaveState.failed] when a save fails. A failure keeps the pending note;
/// [NoteAutosave.retry] or the next edit saves it again. Nothing is
/// discarded without a save.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/local_store_settings.dart';
import '../models/local_note.dart';
import 'editor_files.dart';
import 'local_note_store.dart';

enum SaveState { saving, saved, failed }

/// Where an open paper editor keeps its edits (annotations#44): the autosave
/// of a local note, or the sharing of an Instant room.
abstract interface class PaperSaver {
  /// The state for the page indicator.
  ValueListenable<SaveState> get state;

  /// Records an accepted edit; it is kept after a short pause.
  void edited(LocalNoteDraft note);

  /// Keeps the pending edit again after a failure.
  Future<void> retry();

  /// Keeps the pending edit now, for example before the editor closes.
  Future<void> flush();

  /// The files of the edited document.
  EditorFiles get files;

  void dispose();
}

final class NoteAutosave implements PaperSaver {
  NoteAutosave(this.store, {this.settings = const LocalStoreSettings()});

  final LocalNoteStore store;
  final LocalStoreSettings settings;

  /// The save state for the page indicator (annotations#26).
  @override
  final ValueNotifier<SaveState> state = ValueNotifier(SaveState.saved);

  @override
  EditorFiles get files => store;

  LocalNoteDraft? _pending;
  Timer? _timer;
  Future<void>? _running;

  /// The last committed state, or null before the first save.
  LocalNote? get saved => _saved;
  LocalNote? _saved;

  /// The latest edit that is not committed, or null.
  LocalNoteDraft? get pending => _pending;

  /// Records an edit. The save starts after [LocalStoreSettings.autosaveDelay]
  /// without a newer edit.
  @override
  void edited(LocalNoteDraft note) {
    _pending = note;
    state.value = SaveState.saving;
    _timer?.cancel();
    _timer = Timer(settings.autosaveDelay, () {
      _timer = null;
      _start();
    });
  }

  /// Saves the pending note again after a failure.
  @override
  Future<void> retry() => flush();

  /// Saves the pending note now and waits for the commit, for example before
  /// the note closes. A failure shows as [SaveState.failed].
  @override
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _running;
    if (_pending != null) await _start();
  }

  Future<void> _start() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<void> _drain() async {
    // A running timer means a newer edit waits for its pause; it starts the
    // next save itself.
    while (_pending != null && _timer == null) {
      final note = _pending!;
      _pending = null;
      state.value = SaveState.saving;
      try {
        _saved = await store.save(note);
      } on Object {
        _pending ??= note;
        _timer?.cancel();
        _timer = null;
        state.value = SaveState.failed;
        return;
      }
    }
    if (_pending == null && _timer == null) state.value = SaveState.saved;
  }

  /// Stops the timer. Call [flush] first to keep the pending edit.
  @override
  void dispose() {
    _timer?.cancel();
    state.dispose();
  }
}
