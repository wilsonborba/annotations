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

/// How an image is shown (H6 section 4 point 3).
enum ImageKind { band, row, cardOf2, cardOf3, state }

/// One landing image: its target id (H6 section 4), the file and the shape
/// the map gives its place. The image shows whole inside that shape.
class LandingImage {
  const LandingImage(
    this.id,
    this.file,
    this.kind,
    this.ratio, {
    this.tall = false,
  });

  final String id;
  final String file;
  final ImageKind kind;

  /// True when the file is taller than wide: beside text it shows at most
  /// 280 px wide (H6 section 4 point 2).
  final bool tall;

  /// Width divided by height, from the H6 map.
  final double ratio;

  String get asset => 'lib/presentation/frontend/assets/images/$file';
}

const _w169 = 16 / 9, _w43 = 4 / 3, _w32 = 3 / 2;

/// The 43 images by target id (H6 section 4 points 4 to 9).
const landingImages = <String, LandingImage>{
  'O01': LandingImage(
    'O01',
    'O01_hero_tablet_writing.webp',
    ImageKind.row,
    _w169,
  ),
  'O02': LandingImage(
    'O02',
    'O02_instant_collab_laptops.webp',
    ImageKind.cardOf2,
    _w43,
  ),
  'O03': LandingImage(
    'O03',
    'O03_notes_study_alone.webp',
    ImageKind.cardOf2,
    _w43,
  ),
  'O04': LandingImage(
    'O04',
    'O04_browse_notes_phone.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O05': LandingImage(
    'O05',
    'O05_open_instant_review.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O06': LandingImage(
    'O06',
    'O06_download_closed_laptop.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O07': LandingImage(
    'O07',
    'O07_writer_platforms_side_by_side.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O08': LandingImage(
    'O08',
    'O08_phone_platforms_typing.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O09': LandingImage(
    'O09',
    'O09_browser_window_monitor.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'O10': LandingImage(
    'O10',
    'O10_training_notice_band_pages.webp',
    ImageKind.band,
    21 / 9,
  ),
  'F01': LandingImage(
    'F01',
    'F01_digital_paper_desk.webp',
    ImageKind.row,
    _w43,
  ),
  'F02': LandingImage(
    'F02',
    'F02_type_and_draw_keyboard.webp',
    ImageKind.row,
    _w43,
  ),
  'F03': LandingImage(
    'F03',
    'F03_four_pens_collection.webp',
    ImageKind.row,
    _w43,
  ),
  'F04': LandingImage(
    'F04',
    'F04_point_editing_curves.webp',
    ImageKind.row,
    _w43,
  ),
  'F05': LandingImage(
    'F05',
    'F05_erasers_precision_lens.webp',
    ImageKind.row,
    _w43,
  ),
  'F06': LandingImage(
    'F06',
    'F06_backgrounds_notebooks.webp',
    ImageKind.row,
    _w43,
  ),
  'F07': LandingImage(
    'F07',
    'F07_cards_clipped_notes.webp',
    ImageKind.row,
    _w43,
  ),
  'F08': LandingImage(
    'F08',
    'F08_reports_charts_graphs.webp',
    ImageKind.row,
    _w43,
  ),
  'F09': LandingImage('F09', 'F09_tasks_todo_prompt.webp', ImageKind.row, _w43),
  'F10': LandingImage(
    'F10',
    'F10_handwriting_to_text.webp',
    ImageKind.row,
    _w43,
  ),
  'F11': LandingImage(
    'F11',
    'F11_pdf_and_print_stack.webp',
    ImageKind.row,
    _w43,
  ),
  'F12': LandingImage(
    'F12',
    'F12_quizzes_laptop_study.webp',
    ImageKind.row,
    _w43,
  ),
  'F13': LandingImage(
    'F13',
    'F13_media_to_text_audio.webp',
    ImageKind.row,
    _w43,
  ),
  'F14': LandingImage(
    'F14',
    'F14_instant_laptops_timer.webp',
    ImageKind.row,
    _w43,
  ),
  'F15': LandingImage(
    'F15',
    'F15_public_notes_library.webp',
    ImageKind.row,
    _w43,
  ),
  'F16': LandingImage(
    'F16',
    'F16_view_lock_focus_night.webp',
    ImageKind.row,
    _w43,
  ),
  'H01': LandingImage(
    'H01',
    'H01_write_device_transit.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'H02': LandingImage(
    'H02',
    'H02_sign_in_key_badge.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'H03': LandingImage(
    'H03',
    'H03_publish_notice_board.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'H04': LandingImage(
    'H04',
    'H04_instant_life_cafe_phones.webp',
    ImageKind.row,
    _w32,
  ),
  'H05': LandingImage(
    'H05',
    'H05_review_draft_corrections.webp',
    ImageKind.row,
    _w32,
  ),
  'H06': LandingImage(
    'H06',
    'H06_local_note_home_desk.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'H07': LandingImage(
    'H07',
    'H07_private_sync_bag.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'H08': LandingImage(
    'H08',
    'H08_public_note_shared_table.webp',
    ImageKind.cardOf3,
    _w32,
  ),
  'E01': LandingImage(
    'E01',
    'E01_engineering_header_blueprint.webp',
    ImageKind.row,
    _w169,
  ),
  'E02': LandingImage(
    'E02',
    'E02_engineering_open_source_board.webp',
    ImageKind.row,
    _w32,
  ),
  'E03': LandingImage(
    'E03',
    'E03_engineering_own_model_data.webp',
    ImageKind.row,
    _w32,
  ),
  'D01': LandingImage(
    'D01',
    'D01_download_header_multidevice.webp',
    ImageKind.row,
    _w169,
  ),
  'D02': LandingImage(
    'D02',
    'D02_download_mac_linux_keyboard.webp',
    ImageKind.row,
    _w32,
  ),
  'D03': LandingImage(
    'D03',
    'D03_download_iphone_ipad_devices.webp',
    ImageKind.row,
    _w32,
  ),
  'S01': LandingImage(
    'S01',
    'S01_app_note_not_found_empty.webp',
    ImageKind.state,
    1,
  ),
  'S02': LandingImage(
    'S02',
    'S02_app_instant_room_expired.webp',
    ImageKind.state,
    1,
  ),
  'S03': LandingImage(
    'S03',
    'S03_app_no_search_results_empty.webp',
    ImageKind.state,
    1,
  ),
};

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
