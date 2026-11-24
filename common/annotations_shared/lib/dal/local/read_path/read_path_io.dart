import 'dart:io';
import 'dart:typed_data';

/// The bytes of the file at [path].
Future<Uint8List> readPath(String path) => File(path).readAsBytes();
