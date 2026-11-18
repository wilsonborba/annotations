/// Opens the local note store in the app support folder of the device
/// (technical decision 12). Only installed apps call it; the browser app has
/// no local Notes (D1.2).
library;

import 'package:path_provider/path_provider.dart';

import '../../core/local_store_settings.dart';
import 'sqlite_note_store.dart';

Future<SqliteNoteStore> openDeviceNoteStore({
  LocalStoreSettings settings = const LocalStoreSettings(),
}) async => SqliteNoteStore.open(
  (await getApplicationSupportDirectory()).path,
  settings: settings,
);
