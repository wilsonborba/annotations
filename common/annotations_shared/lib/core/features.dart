import 'package:flutter/foundation.dart';

import 'platform_profile.dart';

/// How a profile offers a feature.
enum Availability {
  /// The feature is shown and can be used.
  available,

  /// The feature is shown, but its content cannot be edited.
  readOnly,

  /// The feature is not shown.
  absent,
}

/// Code switches for features that wait for a release.
abstract final class FeatureSwitches {
  /// Stays off until a handwriting model release exists (plan Phase 7).
  static const bool transcription = false;
}

/// One feature per row of the A2 capability matrix, in matrix order.
///
/// The browser has no Notes editor ([Feature.fullWriterWorkspace],
/// [Feature.typedNotesEditing]), so its editor cells apply to Instant rooms.
/// UI limits never change server permissions or the owner API.
enum Feature {
  // Purpose
  fullWriterWorkspace,
  publicDiscoveryFeed,
  // Notes
  localNotesOffline,
  typedNotesEditing,
  complexOwnNotes,
  publishedNotesReading,
  // Canvas
  fixedLogicalPaper,
  placementControls,
  textLimitFeedback,
  // Drawing
  pensWithPressure,
  editableCurves,
  erasers,
  paperBackgrounds,
  // Controls
  toolbarFocusViewLock,
  systemKeyboardInput,
  multiSelectClipboard,
  // History
  notesUndoRedo,
  instantUndoRedo,
  // Files
  fileCards,
  editableBackupRestore,
  // PDF
  pdfExport,
  // Transcription
  handwritingTranscription,
  transcriptionDrafts,
  // Models
  modelDownload,
  // Training
  trainingFeedback,
  // Cortex
  cortexProcessing,
  // Reports
  reportsCreateUpdate,
  reportsSnapshotDisplay,
  reportsExportProtection,
  // Tasks
  taskCards,
  // Certifications
  quizPreparation,
  quizTaking,
  // Organization
  projectsAndTags,
  stableIdentity,
  // Cloud
  manualPrivateSync,
  publishAndDelete,
  // Instant
  instantRooms,
  instantEditing,
  // Account
  accountSession,
  // Operations
  safeTelemetry,
  // UI/UX
  designRules,
  // Scope exclusions
  excludedThisRelease,
}

/// Availability of one feature for each profile.
@immutable
class FeatureRow {
  const FeatureRow(this.fullWriter, this.phone, this.browser);

  final Availability fullWriter;
  final Availability phone;
  final Availability browser;

  Availability of(PlatformProfile profile) => switch (profile) {
    PlatformProfile.fullWriter => fullWriter,
    PlatformProfile.phone => phone,
    PlatformProfile.browser => browser,
  };
}

const _a = Availability.available;
const _r = Availability.readOnly;
const _x = Availability.absent;

/// The A2 capability matrix as code configuration: full writer, phone,
/// browser.
const Map<Feature, FeatureRow> featureTable = {
  // Full writer only; the browser has no lasting Notes editor.
  Feature.fullWriterWorkspace: FeatureRow(_a, _x, _x),
  // Full writers open the browser instead of a built-in feed.
  Feature.publicDiscoveryFeed: FeatureRow(_x, _a, _a),
  // Phones: simple typed notes. No local Notes authoring in the browser.
  Feature.localNotesOffline: FeatureRow(_a, _a, _x),
  // Phones: simple controls. Browser: read-only.
  Feature.typedNotesEditing: FeatureRow(_a, _a, _r),
  // Phones preserve all objects read-only; browser reads own synced notes.
  Feature.complexOwnNotes: FeatureRow(_a, _r, _r),
  // Full writers: own authoring preview; other authors open the browser.
  Feature.publishedNotesReading: FeatureRow(_a, _a, _a),
  // Phones preserve it on complex-note read; browser Instant per device.
  Feature.fixedLogicalPaper: FeatureRow(_a, _r, _a),
  // No complex authoring UI on phones; browser Instant on desktop.
  Feature.placementControls: FeatureRow(_a, _x, _a),
  // Phones: supported typed editing. Browser: Instant editing.
  Feature.textLimitFeedback: FeatureRow(_a, _a, _a),
  // Where the device exposes useful input; browser Instant full editor.
  Feature.pensWithPressure: FeatureRow(_a, _x, _a),
  // Phones display curves only.
  Feature.editableCurves: FeatureRow(_a, _r, _a),
  // No drawing editor on phones.
  Feature.erasers: FeatureRow(_a, _x, _a),
  // Phones display existing backgrounds; browser Instant editor.
  Feature.paperBackgrounds: FeatureRow(_a, _r, _a),
  // Phones: only relevant simple controls. Browser: Instant adapts.
  Feature.toolbarFocusViewLock: FeatureRow(_a, _a, _a),
  // System and hardware input only, no custom keyboard.
  Feature.systemKeyboardInput: FeatureRow(_a, _a, _a),
  // Phones: text actions only. Browser: Instant device controls.
  Feature.multiSelectClipboard: FeatureRow(_a, _a, _a),
  // 100 steps; phones for simple typed Notes; no Notes editing in browser.
  Feature.notesUndoRedo: FeatureRow(_a, _a, _x),
  // Explicit exclusion on every profile.
  Feature.instantUndoRedo: FeatureRow(_x, _x, _x),
  // Phones display existing cards; browser displays published, Instant per
  // device.
  Feature.fileCards: FeatureRow(_a, _r, _a),
  // Phones: native backup/restore, complex restored notes stay read-only.
  Feature.editableBackupRestore: FeatureRow(_a, _a, _x),
  // Export of the available reading representations.
  Feature.pdfExport: FeatureRow(_a, _a, _a),
  // Phones and browser read accepted Typed.
  Feature.handwritingTranscription: FeatureRow(_a, _r, _r),
  // Phones display where available; browser only saved/published content.
  Feature.transcriptionDrafts: FeatureRow(_a, _r, _r),
  // Signed-in model workflow on full writers only.
  Feature.modelDownload: FeatureRow(_a, _x, _x),
  // Mandatory for integrated transcription; no new phone or browser tool.
  Feature.trainingFeedback: FeatureRow(_a, _x, _x),
  // Explicit and default-off on full writers; others read results.
  Feature.cortexProcessing: FeatureRow(_a, _r, _r),
  // Writer workflow online; existing embeds read-only elsewhere.
  Feature.reportsCreateUpdate: FeatureRow(_a, _r, _r),
  Feature.reportsSnapshotDisplay: FeatureRow(_a, _a, _a),
  Feature.reportsExportProtection: FeatureRow(_a, _a, _a),
  // Writer workflow online; others read existing or permitted cards.
  Feature.taskCards: FeatureRow(_a, _r, _r),
  // Writer workflow; existing quiz links open the browser elsewhere.
  Feature.quizPreparation: FeatureRow(_a, _r, _r),
  // No quiz player in Annotations: quizzes run in Certifications.
  Feature.quizTaking: FeatureRow(_x, _x, _x),
  // Phones: own typed-note organization. Browser: read authorized projects.
  Feature.projectsAndTags: FeatureRow(_a, _a, _r),
  Feature.stableIdentity: FeatureRow(_a, _a, _a),
  // Browser reads synced own notes only.
  Feature.manualPrivateSync: FeatureRow(_a, _a, _r),
  // Phones: relevant typed Notes actions. Browser: read-only UI.
  Feature.publishAndDelete: FeatureRow(_a, _a, _r),
  Feature.instantRooms: FeatureRow(_a, _a, _a),
  // Phones: simple typed controls; complex content stays displayed.
  Feature.instantEditing: FeatureRow(_a, _a, _a),
  Feature.accountSession: FeatureRow(_a, _a, _a),
  Feature.safeTelemetry: FeatureRow(_a, _a, _a),
  Feature.designRules: FeatureRow(_a, _a, _a),
  // User-key encryption, personas, future Cortex retrieval.
  Feature.excludedThisRelease: FeatureRow(_x, _x, _x),
};

/// Features that stay absent while [FeatureSwitches.transcription] is off.
const Set<Feature> transcriptionFeatures = {
  Feature.handwritingTranscription,
  Feature.transcriptionDrafts,
  Feature.modelDownload,
  Feature.trainingFeedback,
};

/// Feature availability for one profile. Handlers and widgets ask this
/// object; they never read the platform themselves.
@immutable
class Features {
  const Features(
    this.profile, {
    this.transcription = FeatureSwitches.transcription,
  });

  final PlatformProfile profile;

  /// Whether the transcription switch is on.
  final bool transcription;

  Availability availability(Feature feature) {
    if (!transcription && transcriptionFeatures.contains(feature)) {
      return Availability.absent;
    }
    return featureTable[feature]!.of(profile);
  }

  /// True when the feature is shown, editable or read-only.
  bool isAvailable(Feature feature) =>
      availability(feature) != Availability.absent;

  /// True when the feature is shown but its content cannot be edited.
  bool isReadOnly(Feature feature) =>
      availability(feature) == Availability.readOnly;
}

/// The profile of the running app, decided once at start.
abstract final class AppFeatures {
  static Features? _current;

  /// Features of the running app. Call [start] first.
  static Features get current =>
      _current ?? (throw StateError('AppFeatures.start was not called.'));

  /// Detects the profile once. Later calls return the first result, so
  /// window resize and rotation never change the profile.
  static Future<Features> start({
    Future<PlatformProfile> Function() detect = detectPlatformProfile,
  }) async {
    final existing = _current;
    if (existing != null) return existing;
    final profile = await detect();
    return _current ??= Features(profile);
  }

  /// The detected profile, or null before [start] (tests that do not start).
  static PlatformProfile? get profile => _current?.profile;

  @visibleForTesting
  static void reset() => _current = null;
}
