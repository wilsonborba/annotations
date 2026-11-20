import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/landing_settings.dart';
import 'tokens.dart';

/// One provided image by its target id (H6 section 4): it shows whole, never
/// cropped, in the mapped shape of its place, with radius 8 and the same
/// file in both modes. A missing file keeps the shape as a solid neutral
/// surface.
class LandingPicture extends StatelessWidget {
  const LandingPicture(this.id, {super.key, this.maxWidth});

  final String id;

  /// The widest the image may show, such as 280 for a tall image beside
  /// text or a state image.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final image = landingImages[id]!;
    Widget missing(BuildContext context, Object _, StackTrace? _) =>
        ColoredBox(color: context.colors.subtle);
    // Every image fills the shape the H6 map gives its place and shows
    // whole inside it, so a page keeps its layout for any file.
    final picture = AspectRatio(
      aspectRatio: image.ratio,
      child: image.svg
          ? SvgPicture.asset(
              image.asset,
              package: 'annotations_shared',
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: missing,
            )
          : Image.asset(
              image.asset,
              package: 'annotations_shared',
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: missing,
            ),
    );
    final shown = ClipRRect(
      key: Key('image-$id'),
      borderRadius: BorderRadius.circular(8),
      child: picture,
    );
    return maxWidth == null
        ? shown
        : Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth!),
              child: shown,
            ),
          );
  }
}

/// A state image above its message in an app screen (S01 to S03).
class StatePicture extends StatelessWidget {
  const StatePicture(this.id, {super.key});

  final String id;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: LandingPicture(id, maxWidth: 280),
  );
}
