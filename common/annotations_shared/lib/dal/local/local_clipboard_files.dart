/// The file side of the clipboard for local notes (annotations#24 port,
/// annotations#25 store). Every file is a managed copy in the local store;
/// nothing is fetched or uploaded. The cloud side is annotations#34.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../domain/models/note_document.dart';
import '../../domain/services/local_note_store.dart';
import '../../domain/services/object_clipboard.dart';

final class LocalClipboardFiles implements ClipboardFiles {
  const LocalClipboardFiles(this.store);

  final LocalNoteStore store;

  /// A local file is usable when the store holds its managed copy. A paste
  /// of an item whose file is not on this device is then rejected, so a
  /// note never references a missing attachment (D2.4).
  @override
  Future<bool> canUse(NoteDocument document, String fileId) async =>
      await store.attachment(fileId) != null;

  @override
  Future<Uint8List?> pictureBytes(String fileId) async {
    final file = await store.attachment(fileId);
    if (file == null || !file.type.startsWith('image/')) return null;
    return store.readAttachment(fileId);
  }

  /// Keeps a PNG, JPEG, GIF, WebP or BMP picture. Its natural size is the
  /// pixel size, one logical page unit per pixel (technical decision 1).
  @override
  Future<StoredPicture?> storePicture(
    NoteDocument document,
    Uint8List bytes,
  ) async {
    final format = pictureFormat(bytes);
    if (format == null) return null;
    final int width, height;
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
      descriptor.dispose();
      buffer.dispose();
    } on Object {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    final file = await store.importBytes(
      bytes,
      name: 'image.${format.extension}',
      type: format.type,
    );
    return StoredPicture(file.id, width, height);
  }

  @override
  Future<void> discardPicture(String fileId) => store.discardAttachment(fileId);
}

/// A picture format that the app keeps from the clipboard.
typedef PictureFormat = ({String type, String extension});

/// The format of [bytes] from their signature, or null.
PictureFormat? pictureFormat(Uint8List bytes) {
  bool starts(List<int> signature, [int at = 0]) {
    if (bytes.length < at + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[at + i] != signature[i]) return false;
    }
    return true;
  }

  if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return (type: 'image/png', extension: 'png');
  }
  if (starts([0xFF, 0xD8, 0xFF])) return (type: 'image/jpeg', extension: 'jpg');
  if (starts('GIF8'.codeUnits)) return (type: 'image/gif', extension: 'gif');
  if (starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8)) {
    return (type: 'image/webp', extension: 'webp');
  }
  if (starts('BM'.codeUnits)) return (type: 'image/bmp', extension: 'bmp');
  return null;
}
