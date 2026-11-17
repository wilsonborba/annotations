/// Ink settings that the alignment left to implementation (B6.3, B10: "exact
/// fitting tolerance" and "point simplification without visible damage").
///
/// They control how editable nodes are fitted and how ink is cut and drawn.
/// They never change a stored stroke: brush appearance belongs to the versioned
/// brush definitions in the domain, not to these values. All lengths are
/// logical page units (one unit is one logical pixel at zoom 1.0).
final class InkSettings {
  const InkSettings({
    this.fitTolerance = 0.5,
    this.cornerAngle = 1.2,
    this.cornerWindow = 3,
    this.flattenTolerance = 0.1,
    this.minFragmentLength = 0.5,
  });

  /// The largest distance between a raw sample and the fitted node path, and
  /// between the node path and the line through the samples. Half a logical
  /// pixel: below what a reader sees at zoom 1.0, while a typical handwritten
  /// letter keeps a few nodes instead of every sample.
  final double fitTolerance;

  /// A change of direction above this angle (radians, about 69 degrees) makes
  /// a corner node instead of a smooth node.
  final double cornerAngle;

  /// The distance on each side of a sample that measures its direction change,
  /// so that hand tremor between close samples does not make corners.
  final double cornerWindow;

  /// The largest distance between a curve and the straight pieces that draw,
  /// hit test or cut it.
  final double flattenTolerance;

  /// A partial erase drops a remaining piece of a stroke that is shorter than
  /// this, so that no speck of ink stays behind.
  final double minFragmentLength;
}
