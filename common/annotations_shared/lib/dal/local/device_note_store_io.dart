/// Native device-store opener. Imported only on platforms with dart:io.
library;

import 'package:path_provider/path_provider.dart';

import '../../core/local_store_settings.dart';
import '../../domain/services/local_note_store.dart';
import 'sqlite_note_store.dart';

Future<LocalNoteStore> openDeviceNoteStore({
  LocalStoreSettings settings = const LocalStoreSettings(),
}) async => SqliteNoteStore.open(
  (await getApplicationSupportDirectory()).path,
  settings: settings,
);
