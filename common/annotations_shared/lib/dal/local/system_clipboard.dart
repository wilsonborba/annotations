/// The system clipboard of the platform, for copy to and paste from other
/// apps (B2 G1: text goes as plain text, pictures go as pictures).
///
/// Plain text uses the Flutter services clipboard. HTML and images use
/// quill_native_bridge, the platform clipboard plugin that the text engine
/// already ships (annotations#23). Text and a picture in one clipboard item
/// use super_clipboard, the only maintained plugin that writes several
/// formats at once on every platform (annotations#24). A feature that the
/// platform does not support reads as null or writes nothing. Nothing here fetches a remote
/// resource or runs script: HTML comes back as a string for the sanitizer.
library;

import 'package:flutter/services.dart';
import 'package:quill_native_bridge/quill_native_bridge.dart';
import 'package:super_clipboard/super_clipboard.dart' as multi;

/// The port that the clipboard service uses. Tests pass a fake.
abstract interface class SystemClipboard {
  /// Writes plain text. An empty text clears the text of the clipboard.
  Future<void> writeText(String text);

  /// Writes a picture (encoded image bytes). False when the platform cannot.
  Future<bool> writeImage(Uint8List bytes);

  /// Writes plain text and a PNG picture as one clipboard item, so a text
  /// editor pastes the text and an image app the picture. False when the
  /// platform cannot.
  Future<bool> writeTextAndImage(String text, Uint8List png);

  /// The plain text, or null.
  Future<String?> readText();

  /// The HTML that another app copied, or null (also when not supported).
  Future<String?> readHtml();

  /// The copied picture as encoded bytes, or null.
  Future<Uint8List?> readImage();
}

/// The system clipboard of the running platform.
final class FlutterSystemClipboard implements SystemClipboard {
  const FlutterSystemClipboard();

  static final _bridge = QuillNativeBridge();

  Future<bool> _supports(QuillNativeBridgeFeature feature) async {
    try {
      return await _bridge.isSupported(feature);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<bool> writeImage(Uint8List bytes) async {
    if (!await _supports(QuillNativeBridgeFeature.copyImageToClipboard)) {
      return false;
    }
    try {
      await _bridge.copyImageToClipboard(bytes);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> writeTextAndImage(String text, Uint8List png) async {
    final clipboard = multi.SystemClipboard.instance;
    if (clipboard == null) return false;
    try {
      final item = multi.DataWriterItem()
        ..add(multi.Formats.plainText(text))
        ..add(multi.Formats.png(png));
      await clipboard.write([item]);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<String?> readText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Future<String?> readHtml() async {
    if (!await _supports(QuillNativeBridgeFeature.getClipboardHtml)) {
      return null;
    }
    try {
      return await _bridge.getClipboardHtml();
    } on Object {
      return null;
    }
  }

  @override
  Future<Uint8List?> readImage() async {
    if (!await _supports(QuillNativeBridgeFeature.getClipboardImage)) {
      return null;
    }
    try {
      return await _bridge.getClipboardImage();
    } on Object {
      return null;
    }
  }
}
