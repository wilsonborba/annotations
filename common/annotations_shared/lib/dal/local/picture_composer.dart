/// Renders the selected pictures as they are laid out on the page into one
/// picture, for copy to other apps (B2 G1: pictures go as pictures).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// One picture: its encoded bytes and its rectangle in page units.
typedef PlacedPicture = ({
  Uint8List bytes,
  double left,
  double top,
  double width,
  double height,
});

/// The port of the clipboard service. Tests pass a fake.
abstract interface class PictureComposer {
  /// One PNG with every picture at its place, relative to the outside
  /// rectangle of all of them, one pixel per page unit (scaled down when a
  /// side would pass the limit). Null when no picture can be decoded.
  Future<Uint8List?> compose(List<PlacedPicture> pictures);
}

/// The composer of the running app, with the Flutter image codecs.
final class UiPictureComposer implements PictureComposer {
  const UiPictureComposer({this.maxSide = 4096});

  /// The longest side of the result in pixels.
  final int maxSide;

  @override
  Future<Uint8List?> compose(List<PlacedPicture> pictures) async {
    if (pictures.isEmpty) return null;
    final left = pictures.map((p) => p.left).reduce(math.min);
    final top = pictures.map((p) => p.top).reduce(math.min);
    final right = pictures.map((p) => p.left + p.width).reduce(math.max);
    final bottom = pictures.map((p) => p.top + p.height).reduce(math.max);
    final side = math.max(right - left, bottom - top);
    if (side <= 0) return null;
    final scale = math.min(1.0, maxSide / side);
    final width = math.max(1, ((right - left) * scale).ceil());
    final height = math.max(1, ((bottom - top) * scale).ceil());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
    var drawn = 0;
    for (final p in pictures) {
      final ui.Image image;
      try {
        final codec = await ui.instantiateImageCodec(p.bytes);
        image = (await codec.getNextFrame()).image;
      } on Object {
        continue;
      }
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(
          (p.left - left) * scale,
          (p.top - top) * scale,
          p.width * scale,
          p.height * scale,
        ),
        paint,
      );
      image.dispose();
      drawn++;
    }
    final picture = recorder.endRecording();
    if (drawn == 0) {
      picture.dispose();
      return null;
    }
    final result = await picture.toImage(width, height);
    picture.dispose();
    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    result.dispose();
    return data?.buffer.asUint8List();
  }
}
