/// Opens the local note store in the app support folder of an installed app.
/// The browser has no local Notes store (D1.2).
library;

import '../../core/local_store_settings.dart';
import '../../domain/services/local_note_store.dart';
import 'device_note_store_stub.dart'
    if (dart.library.io) 'device_note_store_io.dart'
    as platform;

/// Opens the native store when supported. The web implementation fails if
/// this installed-app-only operation is called by mistake.
Future<LocalNoteStore> openDeviceNoteStore({
  LocalStoreSettings settings = const LocalStoreSettings(),
}) => platform.openDeviceNoteStore(settings: settings);
