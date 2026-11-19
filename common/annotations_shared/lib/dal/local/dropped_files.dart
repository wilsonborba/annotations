/// Files and web links that arrive by drag and drop or in the system
/// clipboard (annotations#34). Only paths and link text are read here; the
/// files are copied by the local store.
library;

import 'dart:async';

import 'package:super_clipboard/super_clipboard.dart';

/// What a drop or the clipboard holds: file paths on this device and web
/// links (or other plain text).
typedef Dropped = ({List<String> paths, List<String> texts});

Future<T?> _value<T extends Object>(DataReader reader, ValueFormat<T> format) {
  if (!reader.canProvide(format)) return Future.value(null);
  final done = Completer<T?>();
  final progress = reader.getValue<T>(
    format,
    (value) {
      if (!done.isCompleted) done.complete(value);
    },
    onError: (_) {
      if (!done.isCompleted) done.complete(null);
    },
  );
  if (progress == null && !done.isCompleted) done.complete(null);
  return done.future;
}

/// The files and texts of [readers], in their order.
Future<Dropped> readDropped(Iterable<DataReader> readers) async {
  final paths = <String>[], texts = <String>[];
  for (final reader in readers) {
    final file = await _value(reader, Formats.fileUri);
    if (file != null && file.isScheme('file')) {
      paths.add(file.toFilePath());
      continue;
    }
    final uri = await _value(reader, Formats.uri);
    if (uri != null) {
      texts.add(uri.uri.toString());
      continue;
    }
    final text = await _value(reader, Formats.plainText);
    if (text != null) texts.add(text);
  }
  return (paths: paths, texts: texts);
}

/// The file paths in the system clipboard (files copied in a file manager).
Future<List<String>> clipboardFilePaths() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return const [];
  try {
    final reader = await clipboard.read();
    return (await readDropped(reader.items)).paths;
  } on Object {
    return const [];
  }
}

/// The data formats a paper drop accepts.
const dropFormats = <DataFormat>[
  Formats.fileUri,
  Formats.uri,
  Formats.plainText,
];
