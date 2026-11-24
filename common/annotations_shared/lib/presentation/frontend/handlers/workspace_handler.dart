import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';

import '../../../domain/models/local_note.dart';
import '../../../domain/services/local_workspace.dart';
import '../../../domain/services/note_sync_service.dart';

/// The state of the writer workspace list: filters, notes, and the backup
/// and removal actions (annotations#38 scope 3, 5, 6).
class WorkspaceHandler extends ChangeNotifier {
  WorkspaceHandler(
    this.workspace, {
    Future<String?> Function(String name)? saveLocation,
    Future<String?> Function()? openBackup,
  }) : _saveLocation = saveLocation ?? _pickSave,
       _openBackup = openBackup ?? _pickOpen;

  final LocalWorkspace workspace;
  final Future<String?> Function(String name) _saveLocation;
  final Future<String?> Function() _openBackup;

  static Future<String?> _pickSave(String name) async =>
      (await fs.getSaveLocation(suggestedName: name))?.path;

  static Future<String?> _pickOpen() async => (await fs.openFile(
    acceptedTypeGroups: const [
      fs.XTypeGroup(label: 'Annotations backup', extensions: ['json']),
    ],
  ))?.path;

  String? projectId, tag;
  List<LocalNote>? notes;
  Object? error;

  Future<void> load() async {
    try {
      notes = await workspace.notes(projectId: projectId, tag: tag);
      error = null;
    } catch (e) {
      error = e;
    }
    notifyListeners();
  }

  void filter({String? project, String? tag}) {
    projectId = project;
    this.tag = tag;
    load();
  }

  Future<String> create() => workspace.createNote();

  /// Writes the note's backup package to a file the user picks. True when
  /// saved, false when the user cancelled; throws when it failed.
  Future<bool> exportBackup(LocalNote note) async {
    final path = await _saveLocation('${note.title ?? 'note'}.json');
    if (path == null) return false;
    final package = await workspace.backup.exportPackage(
      workspace.store,
      note.id,
    );
    await File(path).writeAsString(package, flush: true);
    return true;
  }

  /// Restores a backup file the user picks. True when restored.
  Future<bool> restoreBackup() async {
    final path = await _openBackup();
    if (path == null) return false;
    await workspace.backup.restorePackage(
      workspace.store,
      await File(path).readAsString(),
    );
    await load();
    return true;
  }

  /// Removes the note from this device only (D1.4 deletion scopes).
  Future<void> removeFromDevice(LocalNote note) async {
    final store = workspace.store;
    if (store is! DeletableLocalNoteStore) {
      throw StateError('This store cannot remove notes');
    }
    await store.deleteNote(note.id);
    await load();
  }
}
