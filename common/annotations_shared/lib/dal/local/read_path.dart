/// Reads a picked or dropped file of this device by its path (annotations#44,
/// Instant room files). The browser has no paths: its files come as bytes.
library;

export 'read_path/read_path_stub.dart'
    if (dart.library.io) 'read_path/read_path_io.dart';
