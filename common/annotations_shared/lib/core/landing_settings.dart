/// Public links and release facts of the landing pages (annotations#53,
/// H6 section 3). Only public addresses belong here: no server names, LAN
/// details, internal services or private repositories.
library;

import 'features.dart';

/// A public source repository and the tag the landing links to.
class PublicRepo {
  const PublicRepo(this.name, this.tag);

  final String name;

  /// The newest release tag. Source links point to tagged versions.
  final String tag;

  String get url => 'https://github.com/wilsonborba/$name/tree/$tag';
}

/// The release of one platform. Null fields mean there is no public
/// release yet; the card then shows only its status.
class PlatformRelease {
  const PlatformRelease({
    this.version,
    this.date,
    this.checksum,
    this.installCommand,
  });

  final String? version;

  /// Release date, ISO 8601 (yyyy-mm-dd).
  final String? date;

  /// SHA-256 of the download.
  final String? checksum;

  /// The copy command that installs this release (Mac and Linux).
  final String? installCommand;

  bool get released => version != null;
}

/// The platforms of the Download page, in card order.
enum DownloadPlatform { mac, linux, android, iosIpados }

abstract final class LandingSettings {
  /// The public address of the browser app.
  static const siteAddress = 'https://annotations.asodya.com';
  static const asodya = 'https://asodya.com';
  static const terms = 'https://asodya.com/terms-of-service';
  static const privacy = 'https://asodya.com/privacy-policy';
  static const reports = 'https://reports.asodya.com';
  static const certifications = 'https://certifications.asodya.com';
  static const cortex = 'https://cortex.asodya.com';
  static const apiDocs = 'https://api.asodya.com/docs';

  /// The public repositories of the architecture (H6 section 3 point 11).
  /// screen_trail is the public usage tracking package; asodya_tracking is
  /// not a public repository.
  static const app = PublicRepo('annotations', 'v1.1.0');
  static const notesApi = PublicRepo('annotations_api', 'v1.1.0');
  static const gateway = PublicRepo('api_for_apps', 'v1.3.0');
  static const files = PublicRepo('fsm', 'v0.3.1');
  static const reportsRepo = PublicRepo('reports', 'v3.1.2');
  static const certificationsRepo = PublicRepo('certifications', 'v1.0.0');
  static const cortexRepo = PublicRepo('cortex', 'v2.3.2');
  static const tracking = PublicRepo('screen_trail', 'v0.1.0');

  static const repos = [
    app,
    notesApi,
    gateway,
    files,
    reportsRepo,
    certificationsRepo,
    cortexRepo,
    tracking,
  ];

  /// The release page of the application (Android install steps).
  static const releasesPage =
      'https://github.com/wilsonborba/annotations/releases';

  /// The public source: the copy command of the Download page.
  static const cloneCommand =
      'git clone https://github.com/wilsonborba/annotations.git';

  /// Release facts per platform. iPhone and iPad are not available to the
  /// public yet (X1); the other platforms have no v2 release yet.
  static const releases = <DownloadPlatform, PlatformRelease>{
    DownloadPlatform.mac: PlatformRelease(),
    DownloadPlatform.linux: PlatformRelease(),
    DownloadPlatform.android: PlatformRelease(),
    DownloadPlatform.iosIpados: PlatformRelease(),
  };
}

/// A real screenshot of the app in light and dark (H6 point 13), rendered
/// from the app widgets by test/landing_screens_capture_test.dart.
class AppScreenshot {
  const AppScreenshot(this.name, this.ratio);

  final String name;

  /// Width divided by height.
  final double ratio;

  String asset(bool dark) =>
      'lib/presentation/frontend/assets/images/showcase_${name}_${dark ? 'dark' : 'light'}.webp';
}

const desktopShot = AppScreenshot('desktop', 1280 / 800);
const browserShot = AppScreenshot('browser', 1280 / 800);
const phoneShot = AppScreenshot('phone', 390 / 844);

/// The window frames of the product showcase, in timer order.
enum ShowcasePlatform { mac, linux, browser }

/// The install blocks, in page order (owner direction 2026-11-20).
enum InstallPlatform { mac, linux, tablets, androidPhones, iphone, browser }

/// The groups of the Features page, in page order. Each group gets one
/// color pair of [AppPalette.pairs], by index.
enum FeatureGroup { writing, pageContent, study, sharing }

/// What a feature needs to work.
enum FeatureNeeds {
  /// Works offline, without a login.
  nothing,

  /// Needs internet, no login.
  internet,

  /// Needs internet and sign-in.
  internetAndLogin,
}

/// One row of the Features page: the image id names the row, its strings
/// are `feature<id>Title` and `feature<id>Text`. The row is shown only when
/// [gate] is available on at least one platform profile of the release.
class LandingFeature {
  const LandingFeature(this.image, this.group, this.gate, this.needs);

  final String image;
  final FeatureGroup group;
  final Feature gate;
  final FeatureNeeds needs;
}

/// The Features page rows, in page order (H6 section 4 point 5).
const landingFeatures = <LandingFeature>[
  LandingFeature(
    'F01',
    FeatureGroup.writing,
    Feature.fixedLogicalPaper,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F02',
    FeatureGroup.writing,
    Feature.systemKeyboardInput,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F03',
    FeatureGroup.writing,
    Feature.pensWithPressure,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F04',
    FeatureGroup.writing,
    Feature.editableCurves,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F05',
    FeatureGroup.writing,
    Feature.erasers,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F06',
    FeatureGroup.writing,
    Feature.paperBackgrounds,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F16',
    FeatureGroup.writing,
    Feature.toolbarFocusViewLock,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F07',
    FeatureGroup.pageContent,
    Feature.fileCards,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F08',
    FeatureGroup.pageContent,
    Feature.reportsSnapshotDisplay,
    FeatureNeeds.internetAndLogin,
  ),
  LandingFeature(
    'F09',
    FeatureGroup.pageContent,
    Feature.taskCards,
    FeatureNeeds.internetAndLogin,
  ),
  LandingFeature(
    'F10',
    FeatureGroup.study,
    Feature.handwritingTranscription,
    FeatureNeeds.internetAndLogin,
  ),
  LandingFeature(
    'F11',
    FeatureGroup.study,
    Feature.pdfExport,
    FeatureNeeds.nothing,
  ),
  LandingFeature(
    'F12',
    FeatureGroup.study,
    Feature.quizPreparation,
    FeatureNeeds.internetAndLogin,
  ),
  LandingFeature(
    'F13',
    FeatureGroup.study,
    Feature.cortexProcessing,
    FeatureNeeds.internetAndLogin,
  ),
  LandingFeature(
    'F14',
    FeatureGroup.sharing,
    Feature.instantRooms,
    FeatureNeeds.internet,
  ),
  LandingFeature(
    'F15',
    FeatureGroup.sharing,
    Feature.publishAndDelete,
    FeatureNeeds.internetAndLogin,
  ),
];

/// One part of an Engineering diagram: its label string key and the public
/// repository it links to (null for a part with no repository).
class DiagramPart {
  const DiagramPart(this.label, [this.repo]);

  final String label;
  final PublicRepo? repo;
}

/// The architecture diagram: stages from left to right (top to bottom on a
/// phone); an arrow joins each stage to the next.
const architectureStages = <List<DiagramPart>>[
  [DiagramPart('diagramApps', LandingSettings.app)],
  [DiagramPart('diagramGateway', LandingSettings.gateway)],
  [
    DiagramPart('diagramNotesApi', LandingSettings.notesApi),
    DiagramPart('diagramFiles', LandingSettings.files),
    DiagramPart('diagramReports', LandingSettings.reportsRepo),
    DiagramPart('diagramCertifications', LandingSettings.certificationsRepo),
    DiagramPart('diagramCortex', LandingSettings.cortexRepo),
  ],
];

/// The tracking part under the architecture: usage events go through the
/// gateway and never carry note content.
const trackingStages = <List<DiagramPart>>[
  [DiagramPart('diagramApps', LandingSettings.app)],
  [DiagramPart('diagramTracking', LandingSettings.tracking)],
  [DiagramPart('diagramGateway', LandingSettings.gateway)],
];

/// The editor rules: checked in the app, checked again on the server.
const rulesStages = <List<DiagramPart>>[
  [DiagramPart('diagramDeviceRules', LandingSettings.app)],
  [DiagramPart('diagramServerRules', LandingSettings.notesApi)],
];

/// The own model: from corrections to a measured model version.
const modelStages = <List<DiagramPart>>[
  [DiagramPart('diagramCorrections')],
  [DiagramPart('diagramBatches')],
  [DiagramPart('diagramLanguageTests')],
  [DiagramPart('diagramModelVersion')],
];
