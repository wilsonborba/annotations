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
  List<LocalNote> _accountNotes = const [];
  Object? error;
  int _loadGeneration = 0;

  Map<String, String> get visibleProjects =>
      workspace.catalog.projectsForNotes(_accountNotes);

  List<String> get visibleTags => workspace.catalog.tagsForNotes(_accountNotes);

  void accountChanged() {
    projectId = null;
    tag = null;
    load();
  }

  Future<void> load() async {
    final generation = ++_loadGeneration;
    final accountId = account?.localOwnerId;
    notes = null;
    _accountNotes = const [];
    error = null;
    published.clear();
    notifyListeners();
    try {
      final accountNotes = await workspace.notes(accountId: accountId);
      if (generation != _loadGeneration) return;
      _accountNotes = accountNotes;
      notes = [
        for (final note in accountNotes)
          if ((projectId == null ||
                  workspace.catalog.projectForNote(note.id) == projectId) &&
              (tag == null ||
                  workspace.catalog.tagsForNote(note.id).contains(tag)))
            note,
      ];
      error = null;
      notifyListeners();
      if (account?.signedIn == true && accountId != null && sync != null) {
        for (final note in notes!) {
          if (generation != _loadGeneration) return;
          if (note.accountId != accountId) continue;
          try {
            final state = await sync!.publicationState(
              note,
              accountId: accountId,
            );
            if (generation != _loadGeneration) return;
            if (state?.published == true) {
              published[note.id] = state!.revision;
            }
          } catch (_) {
            // The local library remains readable offline. A cloud action
            // refreshes authoritative publication state before it mutates.
          }
        }
      }
    } catch (e) {
      if (generation == _loadGeneration) error = e;
    }
    if (generation == _loadGeneration) notifyListeners();
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
      accountId: account?.localOwnerId,
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
    final accountId = account?.localOwnerId;
    final allowed = await workspace.loadNoteForAccount(note.id, accountId);
    if (allowed == null) {
      throw StateError('Note is not available to this account');
    }
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
  Future<void> syncNote(LocalNote note) => _cloud(note.id, () {
    _requireLiveAccount();
    return sync!.syncNote(note, accountId: account!.userId);
  });

  /// Restricted embeds that need the warning before publication.
  int restrictedEmbeds(LocalNote note) => countRestrictedEmbeds(note.document);

  Future<void> publish(
    LocalNote note,
    PublicationRepresentation representation, {
    bool allowRestricted = false,
  }) => _cloud(note.id, () async {
    _requireLiveAccount();
    final publication = await sync!.publicationState(
      note,
      accountId: account!.userId,
    );
    final result = await sync!.publishNote(
      note,
      accountId: account!.userId,
      representation: representation,
      publicationRevision: publication?.revision ?? 0,
      allowRestrictedEmbeds: allowRestricted,
    );
    if (!result.published) throw StateError('restricted embeds');
    final revision = result.response?['revision'];
    if (revision is! int) throw StateError('Missing publication revision');
    published[note.id] = revision;
  });

  Future<void> unpublish(LocalNote note) => _cloud(note.id, () async {
    _requireLiveAccount();
    final publication = await sync!.publicationState(
      note,
      accountId: account!.userId,
    );
    if (publication?.published != true) {
      throw StateError('Note is not published');
    }
    await sync!.unpublishNote(
      note.id,
      accountId: account!.userId,
      publicationRevision: publication!.revision,
    );
    published.remove(note.id);
  });

  /// Deletes the cloud copy; the device copy stays, unbound (D1.4).
  Future<void> deleteEverywhere(LocalNote note) => _cloud(note.id, () {
    _requireLiveAccount();
    return sync!.deleteCloudNote(note.id, accountId: account!.userId);
  });

  /// Puts the note in a project; [newName] creates the project first.
  /// Returns false when a project with [newName] exists.
  bool setProject(LocalNote note, {String? projectId, String? newName}) {
    _requireCurrentOwner(note);
    final catalog = workspace.catalog;
    var id = projectId;
    if (newName != null && newName.trim().isNotEmpty) {
      try {
        id = catalog.createLocalProject(
          'p${DateTime.now().microsecondsSinceEpoch}',
          newName,
        );
      } on StateError {
        return false;
      }
    }
    if (id == null) return true;
    catalog.assignNoteToProject(note.id, id);
    load();
    return true;
  }

  void addTag(LocalNote note, String tag) {
    _requireCurrentOwner(note);
    workspace.catalog.addTag(note.id, tag);
    load();
  }

  void _requireCurrentOwner(LocalNote note) {
    final ownerId = account?.localOwnerId;
    if (note.accountId != null && note.accountId != ownerId) {
      throw StateError('Note is not available to this account');
    }
  }

  void _requireLiveAccount() {
    if (!canSync) throw StateError('A live account session is required');
  }
}
