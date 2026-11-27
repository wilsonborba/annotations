import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings.dart';
import '../../dal/local/device_note_store.dart';
import '../../dal/remote/aes_cbc.dart';
import 'installed_account.dart';
import 'native_auth_service.dart';

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
  Future<String> createNote() => _createNote(typedOnly ? _typed : _original);

  /// Creates a separate blank Original linked to an already published Typed
  /// note. The source page itself is never modified.
  Future<String> createHandwrittenStudy(StudySourceReference source) async {
    if (profile != PlatformProfile.fullWriter) {
      throw StateError('Handwritten studies require the full writer.');
    }
    if (source.noteId.length > 128 ||
        source.noteId.isEmpty ||
        !source.noteId.codeUnits.every(
          (unit) => unit >= 0x21 && unit <= 0x7e,
        )) {
      throw ArgumentError.value(source.noteId, 'source.noteId');
    }
    return _createNote(_original, studySource: source);
  }

  Future<String> _createNote(
    DocumentSchema schema, {
    StudySourceReference? studySource,
  }) async {
    final rng = Random.secure();
    final id = List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final document = NoteDocument.fromJson(
      schema.family == DocumentFamily.typed
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
      LocalNoteDraft(
        id: id,
        schema: schema,
        document: document,
        studySource: studySource,
      ),
    );
    return id;
  }

  /// The notes, newest change first, filtered by project and tag.
  Future<List<LocalNote>> notes({
    String? accountId,
    String? projectId,
    String? tag,
  }) async {
    final all = await store.notes();
    return [
      for (final note in all)
        if ((note.accountId == null ||
                (accountId != null && note.accountId == accountId)) &&
            (projectId == null ||
                catalog.projectForNote(note.id) == projectId) &&
            (tag == null || catalog.tagsForNote(note.id).contains(tag)))
          note,
    ];
  }

  /// Loads a note only when it belongs to the active account or is still a
  /// guest note. A deep link must obey the same boundary as the workspace list.
  Future<LocalNote?> loadNoteForAccount(String id, String? accountId) async {
    final note = await store.load(id);
    if (note == null ||
        (note.accountId != null && note.accountId != accountId)) {
      return null;
    }
    return note;
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

/// The installed-app account with the OS secure storage (annotations#36).
InstalledAccount openInstalledAccount(PlatformProfile profile) {
  final client = http.Client();
  return InstalledAccount(
    auth: NativeAuthService(
      client: client,
      storage: OsSecureSessionStorage(),
      gatewayBaseUrl: Uri.parse(Settings.current.apiBase).origin,
    ),
    client: client,
    platform: handoffPlatform(
      defaultTargetPlatform,
      fullWriter: profile == PlatformProfile.fullWriter,
    ),
    open: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
    aes: aesCbcEncrypt,
    appContextKey: Settings.current.appContextKey,
    authBase: Settings.current.authBase,
  );
}
