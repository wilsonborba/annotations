import 'package:flutter/material.dart';

import 'sketch_art.dart';

/// A drawn state image above its message in an app screen: not found,
/// room expired, no results (H6 section 4 point 9, drawn instead of
/// photos after the owner's design review).
class StatePicture extends StatelessWidget {
  const StatePicture(this.id, {super.key});

  final String id;

  static const scenes = {
    'S01': SketchScene.emptyDesk,
    'S02': SketchScene.hourglass,
    'S03': SketchScene.emptyShelf,
  };

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Center(
      child: SizedBox(
        key: Key('image-$id'),
        width: 220,
        child: SketchArt(scenes[id]!),
      ),
    ),
  );
}
