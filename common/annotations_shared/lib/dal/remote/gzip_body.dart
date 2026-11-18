/// Gzip for sync request bodies (annotations#19 part C): the note routes
/// accept `Content-Encoding: gzip`. Browsers never write notes, so the web
/// build has no gzip here and sends the body as it is.
library;

export 'gzip_body_stub.dart' if (dart.library.io) 'gzip_body_io.dart';
