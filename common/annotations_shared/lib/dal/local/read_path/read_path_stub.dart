import 'dart:typed_data';

/// The browser has no file paths; its files come as bytes.
Future<Uint8List> readPath(String path) =>
    Future.error(UnsupportedError('No file paths in the browser'));
