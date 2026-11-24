import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../dal/local/device_note_store.dart';

import '../../core/platform_profile.dart';
import '../models/local_note.dart';
import '../models/note_document.dart';
import 'local_note_store.dart';
import 'note_backup_service.dart';
import 'note_sync_service.dart';

/// The writer workspace of an installed app (annotations#38 scope 3 and 8):
/// the notes on this device, their projects and tags, and the backup. The
/// browser has none (D1.2).
class LocalWorkspace {
  LocalWorkspace({
    required this.store,
    required this.catalog,
    required this.profile,
    NoteBackupService? backup,
  }) : backup = backup ?? NoteBackupService();

  final LocalNoteStore store;
  final ProjectTagCatalog catalog;
  final PlatformProfile profile;
  final NoteBackupService backup;

  static final _original = DocumentSchema('note-original', 1);
  static final _typed = DocumentSchema('note-typed', 1);

  /// Phones write typed notes only; the full writers start on paper (A2/F1).
  bool get typedOnly => profile == PlatformProfile.phone;

  /// Creates an empty, untitled note and returns its id.
  Future<String> createNote() async {
    final rng = Random.secure();
    final id = List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final schema = typedOnly ? _typed : _original;
    final document = NoteDocument.fromJson(
      typedOnly
          ? {'blocks': <Object>[]}
          : {
              'page': {
                'width': 1000,
                'background': {
                  'kind': 'ruled',
                  'spacing': 32,
                  'visibility': 0.5,
                },
              },
              'items': <Object>[],
            },
      schema: schema,
    );
    await store.save(
      LocalNoteDraft(id: id, schema: schema, document: document),
    );
    return id;
  }

  /// The notes, newest change first, filtered by project and tag.
  Future<List<LocalNote>> notes({String? projectId, String? tag}) async {
    final all = await store.notes();
    return [
      for (final note in all)
        if ((projectId == null ||
                catalog.projectForNote(note.id) == projectId) &&
            (tag == null || catalog.tagsForNote(note.id).contains(tag)))
          note,
    ];
  }
}

/// Opens the workspace of this device (installed apps only).
Future<LocalWorkspace> openDeviceWorkspace(PlatformProfile profile) async {
  final store = await openDeviceNoteStore();
  final support = await getApplicationSupportDirectory();
  return LocalWorkspace(
    store: store,
    catalog: ProjectTagCatalog(
      persistenceFile: File('${support.path}/projects_tags.json'),
    ),
    profile: profile,
  );
}

/// True when the first-start intro was seen on this device.
Future<bool> introWasSeen() async {
  try {
    return (await SharedPreferences.getInstance()).getBool(
          'annotations.intro_seen',
        ) ??
        false;
  } catch (_) {
    return false;
  }
}
