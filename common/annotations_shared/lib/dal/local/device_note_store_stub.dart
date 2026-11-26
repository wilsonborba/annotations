/// Browser implementation for the installed-app-only device store.
library;

import '../../core/local_store_settings.dart';
import '../../domain/services/local_note_store.dart';

Future<LocalNoteStore> openDeviceNoteStore({
  LocalStoreSettings settings = const LocalStoreSettings(),
}) async {
  throw UnsupportedError(
    'Device note storage is available in installed apps only.',
  );
}
