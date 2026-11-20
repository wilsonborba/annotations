import '../../../core/features.dart';
import '../../../core/landing_settings.dart';
import '../../../core/platform_profile.dart';

/// What the landing pages show from the release configuration.
class LandingHandler {
  const LandingHandler({this.transcription = FeatureSwitches.transcription});

  /// Whether the transcription switch is on in this release.
  final bool transcription;

  /// A feature is in the release when at least one platform profile shows
  /// it (A2 capability matrix and the release switches).
  bool inRelease(Feature feature) => PlatformProfile.values.any(
    (profile) =>
        Features(profile, transcription: transcription).isAvailable(feature),
  );

  /// The Features page rows of one group, in page order, without the
  /// features that are not in the release.
  List<LandingFeature> rows(FeatureGroup group) => [
    for (final row in landingFeatures)
      if (row.group == group && inRelease(row.gate)) row,
  ];

  /// The groups that have at least one row.
  List<FeatureGroup> get groups => [
    for (final group in FeatureGroup.values)
      if (rows(group).isNotEmpty) group,
  ];
}
