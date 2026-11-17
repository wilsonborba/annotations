import 'package:annotations_shared/core/features.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// A2 matrix, one line per row: full writer, phone, browser.
// a = available, r = read-only, x = absent.
const expectedMatrix = <Feature, String>{
  Feature.fullWriterWorkspace: 'axx',
  Feature.publicDiscoveryFeed: 'xaa',
  Feature.localNotesOffline: 'aax',
  Feature.typedNotesEditing: 'aar',
  Feature.complexOwnNotes: 'arr',
  Feature.publishedNotesReading: 'aaa',
  Feature.fixedLogicalPaper: 'ara',
  Feature.placementControls: 'axa',
  Feature.textLimitFeedback: 'aaa',
  Feature.pensWithPressure: 'axa',
  Feature.editableCurves: 'ara',
  Feature.erasers: 'axa',
  Feature.paperBackgrounds: 'ara',
  Feature.toolbarFocusViewLock: 'aaa',
  Feature.systemKeyboardInput: 'aaa',
  Feature.multiSelectClipboard: 'aaa',
  Feature.notesUndoRedo: 'aax',
  Feature.instantUndoRedo: 'xxx',
  Feature.fileCards: 'ara',
  Feature.editableBackupRestore: 'aax',
  Feature.pdfExport: 'aaa',
  Feature.handwritingTranscription: 'arr',
  Feature.transcriptionDrafts: 'arr',
  Feature.modelDownload: 'axx',
  Feature.trainingFeedback: 'axx',
  Feature.cortexProcessing: 'arr',
  Feature.reportsCreateUpdate: 'arr',
  Feature.reportsSnapshotDisplay: 'aaa',
  Feature.reportsExportProtection: 'aaa',
  Feature.taskCards: 'arr',
  Feature.quizPreparation: 'arr',
  Feature.quizTaking: 'xxx',
  Feature.projectsAndTags: 'aar',
  Feature.stableIdentity: 'aaa',
  Feature.manualPrivateSync: 'aar',
  Feature.publishAndDelete: 'aar',
  Feature.instantRooms: 'aaa',
  Feature.instantEditing: 'aaa',
  Feature.accountSession: 'aaa',
  Feature.safeTelemetry: 'aaa',
  Feature.designRules: 'aaa',
  Feature.excludedThisRelease: 'xxx',
};

const _codes = {
  'a': Availability.available,
  'r': Availability.readOnly,
  'x': Availability.absent,
};

Availability expected(Feature feature, PlatformProfile profile) =>
    _codes[expectedMatrix[feature]![profile.index]]!;

void main() {
  test('profiles are full writer, phone and browser only', () {
    expect(PlatformProfile.values, [
      PlatformProfile.fullWriter,
      PlatformProfile.phone,
      PlatformProfile.browser,
    ]);
  });

  test('the table has exactly the 42 A2 matrix rows', () {
    expect(Feature.values.length, 42);
    expect(featureTable.keys.toSet(), Feature.values.toSet());
    expect(expectedMatrix.keys.toSet(), Feature.values.toSet());
  });

  group('matrix rows with transcription on', () {
    for (final profile in PlatformProfile.values) {
      final features = Features(profile, transcription: true);
      for (final feature in Feature.values) {
        test('${feature.name} on ${profile.name}', () {
          final want = expected(feature, profile);
          expect(features.availability(feature), want);
          expect(features.isAvailable(feature), want != Availability.absent);
          expect(features.isReadOnly(feature), want == Availability.readOnly);
        });
      }
    }
  });

  group('transcription switch', () {
    test('is off in code configuration until a model release exists', () {
      expect(FeatureSwitches.transcription, isFalse);
      expect(const Features(PlatformProfile.fullWriter).transcription, isFalse);
    });

    for (final profile in PlatformProfile.values) {
      test('off keeps transcription features absent on ${profile.name}', () {
        final features = Features(profile);
        for (final feature in Feature.values) {
          final want = transcriptionFeatures.contains(feature)
              ? Availability.absent
              : expected(feature, profile);
          expect(features.availability(feature), want, reason: feature.name);
        }
      });
    }

    test('covers transcription, drafts, model download and feedback', () {
      expect(transcriptionFeatures, {
        Feature.handwritingTranscription,
        Feature.transcriptionDrafts,
        Feature.modelDownload,
        Feature.trainingFeedback,
      });
    });
  });

  group('profile resolution', () {
    PlatformProfile? resolve(
      TargetPlatform platform, {
      bool isWeb = false,
      bool isPad = false,
      double? side,
    }) => resolvePlatformProfile(
      isWeb: isWeb,
      platform: platform,
      isPad: isPad,
      shortestSideDp: side,
    );

    test('macOS and Linux are full writers', () {
      expect(resolve(TargetPlatform.macOS), PlatformProfile.fullWriter);
      expect(resolve(TargetPlatform.linux), PlatformProfile.fullWriter);
    });

    test('iOS uses the iPad idiom', () {
      expect(
        resolve(TargetPlatform.iOS, isPad: true),
        PlatformProfile.fullWriter,
      );
      expect(resolve(TargetPlatform.iOS), PlatformProfile.phone);
      expect(
        resolve(TargetPlatform.iOS, side: 1024),
        PlatformProfile.phone,
        reason: 'iPhone size never decides the iOS profile',
      );
    });

    test('Android tablets have a shortest side of 600 dp or more', () {
      expect(
        resolve(TargetPlatform.android, side: 600),
        PlatformProfile.fullWriter,
      );
      expect(
        resolve(TargetPlatform.android, side: 800),
        PlatformProfile.fullWriter,
      );
      expect(
        resolve(TargetPlatform.android, side: 599.9),
        PlatformProfile.phone,
      );
      expect(resolve(TargetPlatform.android, side: 360), PlatformProfile.phone);
      expect(resolve(TargetPlatform.android), PlatformProfile.phone);
    });

    test('the browser build is the browser profile on every platform', () {
      for (final platform in TargetPlatform.values) {
        expect(
          resolve(platform, isWeb: true, isPad: true, side: 1200),
          PlatformProfile.browser,
        );
      }
    });

    test('Windows and Fuchsia have no profile', () {
      expect(resolve(TargetPlatform.windows), isNull);
      expect(resolve(TargetPlatform.fuchsia), isNull);
    });
  });

  group('runtime detection', () {
    tearDown(AppFeatures.reset);

    // The platform override must be cleared inside the test body.
    void testOn(
      String description,
      TargetPlatform platform,
      Future<void> Function(WidgetTester tester) body,
    ) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await body(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testOn(
      'Android reads the display, not the window',
      TargetPlatform.android,
      (tester) async {
        tester.view.display.devicePixelRatio = 2;
        tester.view.display.size = const Size(1600, 2560);
        tester.view.physicalSize = const Size(400, 600);
        addTearDown(tester.view.reset);
        expect(displayShortestSideDp(tester.platformDispatcher), 800);
        expect(await detectPlatformProfile(), PlatformProfile.fullWriter);

        tester.view.display.size = const Size(720, 1520);
        tester.view.physicalSize = const Size(2000, 2000);
        expect(await detectPlatformProfile(), PlatformProfile.phone);
      },
    );

    testOn('iOS asks the runner for the iPad idiom', TargetPlatform.iOS, (
      tester,
    ) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(platformProfileChannel, null),
      );
      messenger.setMockMethodCallHandler(
        platformProfileChannel,
        (call) async => call.method == 'isPad',
      );
      expect(await detectPlatformProfile(), PlatformProfile.fullWriter);

      messenger.setMockMethodCallHandler(
        platformProfileChannel,
        (call) async => false,
      );
      expect(await detectPlatformProfile(), PlatformProfile.phone);

      messenger.setMockMethodCallHandler(
        platformProfileChannel,
        (call) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await detectPlatformProfile(), PlatformProfile.phone);

      messenger.setMockMethodCallHandler(
        platformProfileChannel,
        (call) async => throw MissingPluginException(),
      );
      expect(await detectPlatformProfile(), PlatformProfile.phone);
    });

    testOn(
      'Windows start fails instead of guessing a profile',
      TargetPlatform.windows,
      (tester) async {
        await expectLater(detectPlatformProfile(), throwsUnsupportedError);
      },
    );

    testOn(
      'profile stays the same after resize and rotation',
      TargetPlatform.android,
      (tester) async {
        tester.view.display.devicePixelRatio = 2;
        tester.view.display.size = const Size(1600, 2560);
        tester.view.physicalSize = const Size(1600, 2560);
        addTearDown(tester.view.reset);

        final started = await AppFeatures.start();
        expect(started.profile, PlatformProfile.fullWriter);
        await tester.pumpWidget(const SizedBox());

        // Split screen to a phone-sized window, then rotate.
        tester.view.physicalSize = const Size(700, 1200);
        await tester.pump();
        tester.view.physicalSize = const Size(1200, 700);
        await tester.pump();
        // Even a changed display size does not change the started profile.
        tester.view.display.size = const Size(720, 1280);
        await tester.pump();

        expect(AppFeatures.current.profile, PlatformProfile.fullWriter);
        expect(identical(await AppFeatures.start(), started), isTrue);
        expect(
          AppFeatures.current.isAvailable(Feature.pensWithPressure),
          isTrue,
        );
      },
    );

    test('current fails before start', () {
      expect(() => AppFeatures.current, throwsStateError);
    });
  });
}
