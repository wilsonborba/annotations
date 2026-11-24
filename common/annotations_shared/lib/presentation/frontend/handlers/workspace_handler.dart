import 'dart:io';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';

import '../../../domain/models/local_note.dart';
import '../../../domain/services/installed_account.dart';
import '../../../domain/services/local_workspace.dart';
import '../../../domain/services/note_sync_service.dart';

/// The state of the writer workspace list: filters, notes, and the backup
/// and removal actions (annotations#38 scope 3, 5, 6).
class WorkspaceHandler extends ChangeNotifier {
  WorkspaceHandler(
    this.workspace, {
    Future<String?> Function(String name)? saveLocation,
    Future<String?> Function()? openBackup,
    this.account,
    this.sync,
  }) : _saveLocation = saveLocation ?? _pickSave,
       _openBackup = openBackup ?? _pickOpen;

  final LocalWorkspace workspace;

  /// The installed account and the cloud service (null: local only).
  final InstalledAccount? account;
  final NoteSyncService? sync;

  /// Cloud actions running or failed, by note id (#38 scope 4).
  final busy = <String>{};
  final failed = <String, Future<void> Function()>{};

  /// Publication revisions of the notes published here, by note id.
  final published = <String, int>{};

  bool get canSync =>
      account?.signedIn == true && sync != null && account!.userId.isNotEmpty;
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

  Future<void> _cloud(String id, Future<void> Function() action) async {
    busy.add(id);
    failed.remove(id);
    notifyListeners();
    try {
      await action();
    } catch (_) {
      failed[id] = () => _cloud(id, action);
    } finally {
      busy.remove(id);
      await load();
    }
  }

  /// Sends the note to the private cloud (explicit, never automatic).
  Future<void> syncNote(LocalNote note) =>
      _cloud(note.id, () => sync!.syncNote(note, accountId: account!.userId));

  /// Restricted embeds that need the warning before publication.
  int restrictedEmbeds(LocalNote note) => countRestrictedEmbeds(note.document);

  Future<void> publish(
    LocalNote note,
    PublicationRepresentation representation, {
    bool allowRestricted = false,
  }) => _cloud(note.id, () async {
    final result = await sync!.publishNote(
      note,
      accountId: account!.userId,
      representation: representation,
      allowRestrictedEmbeds: allowRestricted,
    );
    if (!result.published) throw StateError('restricted embeds');
    final revision = result.response?['revision'];
    published[note.id] = revision is int ? revision : 1;
  });

  Future<void> unpublish(LocalNote note) => _cloud(note.id, () async {
    await sync!.unpublishNote(
      note.id,
      accountId: account!.userId,
      publicationRevision: published[note.id] ?? 1,
    );
    published.remove(note.id);
  });

  /// Deletes the cloud copy; the device copy stays, unbound (D1.4).
  Future<void> deleteEverywhere(LocalNote note) => _cloud(
    note.id,
    () => sync!.deleteCloudNote(
      note.id,
      accountId: account!.userId,
      expectedRevision: note.revision,
    ),
  );
}
