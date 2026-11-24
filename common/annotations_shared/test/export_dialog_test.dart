import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/core/strings.dart';
import 'package:annotations_shared/dal/local/sqlite_note_store.dart';
import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';
import 'package:annotations_shared/domain/services/local_workspace.dart';
import 'package:annotations_shared/domain/services/note_sync_service.dart';
import 'package:annotations_shared/domain/services/pdf_export_mapper.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/presentation/frontend/components/controls.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/handlers/export_handler.dart';
import 'package:annotations_shared/presentation/frontend/widgets/export/export_dialog.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachment_fixtures.dart' show usePdfiumInTests;
import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';

final _origSchema = DocumentSchema(DocumentFamily.original.schemaName, 1);
final _typedSchema = DocumentSchema(DocumentFamily.typed.schemaName, 1);

NoteDocument _originalDoc({List<Map<String, Object?>> items = const []}) =>
    NoteDocument.fromJson({
      'page': {
        'width': 1000,
        'background': {'kind': 'blank'},
      },
      'items': [
        {
          'id': 'txt_1',
          'kind': 'text',
          'x': 20,
          'y': 20,
          'width': 400,
          'height': 40,
          'spans': [
            {'text': 'Cell cycle notes'},
          ],
        },
        ...items,
      ],
    }, schema: _origSchema);

NoteDocument _typedDoc({List<Map<String, Object?>> blocks = const []}) =>
    NoteDocument.fromJson({
      'blocks': [
        {
          'id': 'h1',
          'kind': 'heading',
          'level': 1,
          'spans': [
            {'text': 'Cell cycle notes (typed)'},
          ],
        },
        ...blocks,
      ],
    }, schema: _typedSchema);

Future<ui.Image> _solidImage({int width = 180, int height = 250}) {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return rec.endRecording().toImage(width, height);
}

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  String locale = 'en',
}) => AppScope(
  preferences: Preferences()..locale = locale,
  service: fixtureService(),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: appTheme(brightness),
    home: Material(child: child),
  ),
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for condition');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

class _MissingFileStore implements LocalNoteStore {
  _MissingFileStore([this.paired]);

  final LocalNote? paired;

  @override
  Future<LocalNote?> load(String id) async =>
      paired != null && id == paired!.id ? paired : null;

  @override
  Future<Uint8List?> readAttachment(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalNote _pairedCandidate({
  required String id,
  required DocumentSchema schema,
  String? title = 'Biology Notes',
  String? accountId,
  String? serverNoteId,
}) {
  final now = DateTime.utc(2026);
  return LocalNote(
    id: id,
    schema: schema,
    document: schema.family == DocumentFamily.typed
        ? _typedDoc()
        : _originalDoc(),
    title: title,
    revision: 1,
    createdAt: now,
    updatedAt: now,
    syncState: LocalSyncState.local,
    accountId: accountId,
    serverNoteId: serverNoteId,
  );
}

void main() {
  late Directory cache;
  late Directory root;
  late SqliteNoteStore store;

  setUpAll(() {
    loadAppFonts();
    cache = usePdfiumInTests();
  });
  tearDownAll(() => cache.deleteSync(recursive: true));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('export_test_');
    store = await SqliteNoteStore.open(root.path);
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  group('ExportHandler & B13 coverage', () {
    test('Both is limited to the saved transcription pair', () {
      final original = _pairedCandidate(
        id: 'n1',
        schema: _origSchema,
        accountId: 'account-a',
        serverNoteId: 'server-note-a',
      );
      final validTyped = _pairedCandidate(
        id: 'n1__typed',
        schema: _typedSchema,
        accountId: null,
      );
      final valid = ExportHandler(
        note: original,
        pairedNote: validTyped,
        store: _MissingFileStore(),
      );
      expect(valid.modes, contains(PdfExportMode.both));
      valid.dispose();

      final renamedTyped = ExportHandler(
        note: original,
        pairedNote: _pairedCandidate(
          id: 'n1__typed',
          schema: _typedSchema,
          title: 'Renamed typed view',
        ),
        store: _MissingFileStore(),
      );
      expect(renamedTyped.modes, contains(PdfExportMode.both));
      renamedTyped.dispose();

      final suffixedOriginal = ExportHandler(
        note: _pairedCandidate(id: 'note__typed', schema: _origSchema),
        pairedNote: _pairedCandidate(
          id: 'note__typed__typed',
          schema: _typedSchema,
        ),
        store: _MissingFileStore(),
      );
      expect(suffixedOriginal.modes, contains(PdfExportMode.both));
      suffixedOriginal.dispose();

      for (final unrelated in [
        _pairedCandidate(
          id: 'n1__typed',
          schema: _typedSchema,
          accountId: 'account-b',
        ),
        _pairedCandidate(
          id: 'n1__typed',
          schema: _typedSchema,
          serverNoteId: 'different-cloud-note',
        ),
        _pairedCandidate(id: 'custom-typed-id', schema: _typedSchema),
        _pairedCandidate(id: 'n1__typed', schema: _origSchema),
      ]) {
        final handler = ExportHandler(
          note: original,
          pairedNote: unrelated,
          store: _MissingFileStore(),
        );
        expect(
          handler.modes,
          isNot(contains(PdfExportMode.both)),
          reason:
              'unrelated ${unrelated.id}, ${unrelated.title}, '
              '${unrelated.accountId}, ${unrelated.serverNoteId}',
        );
        handler.dispose();
      }
    });

    testWidgets(
      'paired representation enables Original/Typed/Both, builds two PDFs, previews both, and zips both without companions',
      (tester) async {
        late LocalNote orig;
        late String savePath;
        await tester.runAsync(() async {
          orig = await store.save(
            LocalNoteDraft(
              id: 'n1',
              schema: _origSchema,
              document: _originalDoc(),
              title: 'Biology Notes',
            ),
          );
          await store.save(
            LocalNoteDraft(
              id: 'n1__typed',
              schema: _typedSchema,
              document: _typedDoc(),
              title: 'Biology Notes',
            ),
          );
          savePath = '${root.path}/out.zip';
        });

        final handler = ExportHandler(
          note: orig,
          store: store,
          saveLocation: (_) async => savePath,
        );
        addTearDown(handler.dispose);

        await tester.runAsync(() => handler.build());
        expect(handler.modes, const [
          PdfExportMode.original,
          PdfExportMode.typed,
          PdfExportMode.both,
        ]);
        expect(handler.mode, PdfExportMode.original);
        expect(handler.needsZip, isFalse);
        expect(handler.fileName, 'biology-notes-original.pdf');
        expect(handler.previewPdfs.length, 1);

        await tester.runAsync(() async {
          handler.choose(mode: PdfExportMode.both);
          while (handler.stage == ExportStage.working) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });

        expect(handler.stage, ExportStage.ready);
        expect(handler.output?.pdfs.length, 2);
        expect(handler.output?.companions, isEmpty);
        expect(handler.needsZip, isTrue);
        expect(handler.fileName, 'biology-notes.zip');
        expect(handler.previewPdfs.map((g) => g.filename).toList(), [
          'biology-notes-original.pdf',
          'biology-notes-typed.pdf',
        ]);
        expect(handler.pages.length, greaterThanOrEqualTo(2));
        await tester.runAsync(() async {
          for (var index = 0; index < handler.output!.pdfs.length; index++) {
            final document = await PdfDocument.openData(
              handler.output!.pdfs[index].bytes,
            );
            expect(
              handler.previewPdfs[index].pages.length,
              document.pages.length,
              reason: '${handler.output!.pdfs[index].filename} preview count',
            );
            await document.dispose();
          }
        });

        final saved = await tester.runAsync(() => handler.save());
        expect(saved, isTrue);
        final archive = ZipDecoder().decodeBytes(
          File(savePath).readAsBytesSync(),
        );
        final names = archive.files.map((f) => f.name).toSet();
        expect(names, {
          'biology-notes-original.pdf',
          'biology-notes-typed.pdf',
        });
        for (final f in archive.files) {
          expect(utf8.decode((f.content as List<int>).sublist(0, 5)), '%PDF-');
        }
      },
    );

    testWidgets(
      'renderPdfPages throws on invalid PDF and on empty/null render failures instead of silent ready',
      (tester) async {
        Object? pdfError;
        await tester.runAsync(() async {
          try {
            await renderPdfPages(Uint8List.fromList([1, 2, 3, 4]), 400);
          } catch (e) {
            pdfError = e;
          }
        });
        expect(pdfError, isNotNull);

        late LocalNote orig;
        await tester.runAsync(() async {
          orig = await store.save(
            LocalNoteDraft(
              id: 'n_fail',
              schema: _origSchema,
              document: _originalDoc(),
              title: 'Fail check',
            ),
          );
          await store.save(
            LocalNoteDraft(
              id: 'n_fail__typed',
              schema: _typedSchema,
              document: _typedDoc(),
              title: 'Fail check',
            ),
          );
        });

        final partialImages = <ui.Image>[];
        var call = 0;
        final handler = ExportHandler(
          note: orig,
          store: store,
          renderPages: (bytes, maxPixels) async {
            call++;
            if (call == 1) {
              final img = await _solidImage();
              partialImages.add(img);
              return [img];
            }
            // Second PDF fails in Both mode: must dispose PDF #1's image and mark failed.
            return const [];
          },
        )..mode = PdfExportMode.both;
        addTearDown(handler.dispose);

        await tester.runAsync(() => handler.build());
        expect(handler.stage, ExportStage.failed);
        expect(handler.pages, isEmpty);
        expect(partialImages.single.debugDisposed, isTrue);
      },
    );

    testWidgets(
      'rapid overlapping choose() discards stale build and disposes superseded images cleanly',
      (tester) async {
        late LocalNote orig;
        await tester.runAsync(() async {
          orig = await store.save(
            LocalNoteDraft(
              id: 'n_race',
              schema: _origSchema,
              document: _originalDoc(),
              title: 'Race check',
            ),
          );
        });

        late Completer<List<ui.Image>> slow;
        late Completer<List<ui.Image>> fast;
        late Completer<void> call1;
        late Completer<void> call2;
        late ui.Image staleImage;
        late ui.Image freshImage;
        var calls = 0;
        final handler = ExportHandler(
          note: orig,
          store: store,
          renderPages: (bytes, maxPixels) {
            calls++;
            if (calls == 1) {
              call1.complete();
              return slow.future;
            }
            call2.complete();
            return fast.future;
          },
        );
        addTearDown(handler.dispose);

        await tester.runAsync(() async {
          slow = Completer<List<ui.Image>>();
          fast = Completer<List<ui.Image>>();
          call1 = Completer<void>();
          call2 = Completer<void>();
          final firstBuild = handler.build();
          await call1.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw TimeoutException(
              'call1=${call1.isCompleted} calls=$calls stage=${handler.stage}',
            ),
          );

          final secondBuild = handler.choose(
            paper: PdfPaperSize.letter,
            orientation: PdfOrientation.landscape,
          );
          await call2.future.timeout(const Duration(seconds: 5));

          staleImage = await _solidImage(width: 100, height: 140);
          freshImage = await _solidImage(width: 240, height: 180);

          fast.complete([freshImage]);
          await secondBuild.timeout(const Duration(seconds: 5));
          expect(handler.stage, ExportStage.ready);
          expect(handler.pages, [freshImage]);
          expect(freshImage.debugDisposed, isFalse);

          slow.complete([staleImage]);
          await firstBuild.timeout(const Duration(seconds: 5));

          // Older slow run did not overwrite newer output and disposed its own image.
          expect(handler.stage, ExportStage.ready);
          expect(handler.pages, [freshImage]);
          expect(handler.paper, PdfPaperSize.letter);
          expect(handler.orientation, PdfOrientation.landscape);
          expect(staleImage.debugDisposed, isTrue);
          expect(freshImage.debugDisposed, isFalse);
        });
      },
    );

    testWidgets(
      'save cancel and write failure preserve ready stage without silent loss',
      (tester) async {
        late LocalNote orig;
        await tester.runAsync(() async {
          orig = await store.save(
            LocalNoteDraft(
              id: 'n_save',
              schema: _origSchema,
              document: _originalDoc(),
              title: 'Save test',
            ),
          );
        });

        String? targetPath;
        final handler = ExportHandler(
          note: orig,
          store: store,
          renderPages: (_, _) async => [await _solidImage()],
          saveLocation: (_) async => targetPath,
        );
        addTearDown(handler.dispose);
        await tester.runAsync(() => handler.build());
        expect(handler.stage, ExportStage.ready);

        // User cancels save dialog: remains ready with no error.
        targetPath = null;
        expect(await tester.runAsync(() => handler.save()), isFalse);
        expect(handler.stage, ExportStage.ready);
        expect(handler.saveError, isFalse);

        // Save path write failure: sets saveError while keeping ready stage for retry.
        targetPath = '${root.path}/missing_dir/cannot_write.pdf';
        expect(await tester.runAsync(() => handler.save()), isFalse);
        expect(handler.stage, ExportStage.ready);
        expect(handler.saveError, isTrue);

        // A failed platform save picker also reports the error and remains retryable.
        var pickerFails = true;
        final pickerHandler = ExportHandler(
          note: orig,
          store: store,
          renderPages: (_, _) async => [await _solidImage()],
          saveLocation: (_) async {
            if (pickerFails) throw StateError('save picker failed');
            return targetPath;
          },
        );
        addTearDown(pickerHandler.dispose);
        await tester.runAsync(() => pickerHandler.build());
        expect(await tester.runAsync(() => pickerHandler.save()), isFalse);
        expect(pickerHandler.stage, ExportStage.ready);
        expect(pickerHandler.saveError, isTrue);
        pickerFails = false;

        // Retry with valid path succeeds.
        final validPath = '${root.path}/ok.pdf';
        targetPath = validPath;
        expect(await tester.runAsync(() => handler.save()), isTrue);
        expect(handler.stage, ExportStage.saved);
        expect(handler.saveError, isFalse);
        expect(File(validPath).existsSync(), isTrue);
      },
    );
  });

  group('ExportDialog & NoteEditorPage integration', () {
    testWidgets(
      'NoteEditorPage loads paired note and ExportDialog switches Original/Typed/Both and retries failure',
      (tester) async {
        await tester.runAsync(() async {
          await store.save(
            LocalNoteDraft(
              id: 'n1',
              schema: _origSchema,
              document: _originalDoc(),
              title: 'Cell Cycle',
            ),
          );
          await store.save(
            LocalNoteDraft(
              id: 'n1__typed',
              schema: _typedSchema,
              document: _typedDoc(),
              title: 'Cell Cycle',
            ),
          );
        });

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        SharedPreferences.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          AnnotationsApp(
            key: UniqueKey(),
            trackingEnabled: false,
            service: fixtureService(),
            initialLocation: '/v1/write/n1',
            workspace: LocalWorkspace(
              store: store,
              catalog: ProjectTagCatalog(),
              profile: PlatformProfile.fullWriter,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('editor-export')).evaluate().isNotEmpty,
        );

        await tester.tap(find.byKey(const Key('editor-export')));
        await _pumpUntil(
          tester,
          () =>
              find.byKey(const Key('export-save')).evaluate().isNotEmpty &&
              find.byKey(const Key('preview-page-0')).evaluate().isNotEmpty,
        );

        expect(find.byKey(const Key('export-dialog')), findsOneWidget);
        expect(find.byKey(const Key('export-mode')), findsOneWidget);

        await tester.tap(find.text(translate('exportBoth', 'en')));
        await _pumpUntil(
          tester,
          () =>
              find.text(translate('exportSaveZip', 'en')).evaluate().isNotEmpty,
        );

        expect(
          find.byKey(const Key('preview-file-cell-cycle-original.pdf')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('preview-file-cell-cycle-typed.pdf')),
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('export-preview')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          find.byKey(const Key('preview-file-cell-cycle-typed.pdf')),
          findsOneWidget,
        );
        expect(find.text(translate('exportSaveZip', 'en')), findsOneWidget);
      },
    );

    testWidgets(
      'ExportDialog shows clear failed retry, scrollable preflight, and zero overflow across en/pt-BR/th phone & desktop',
      (tester) async {
        final now = DateTime.now();
        final missingFilesNote = LocalNote(
          id: 'n_pre',
          schema: _origSchema,
          document: _originalDoc(
            items: [
              for (var i = 0; i < 6; i++)
                {
                  'id': 'f_$i',
                  'kind': 'file',
                  'x': 20,
                  'y': 100 + i * 80,
                  'width': 300,
                  'height': 60,
                  'name': 'doc_$i.pdf',
                  'file_id': 'missing_$i',
                  'type': 'application/pdf',
                  'size': 100,
                },
              {
                'id': 'rep_priv',
                'kind': 'reports_embed',
                'x': 20,
                'y': 700,
                'width': 300,
                'height': 80,
                'report_id': 'chart_secret',
                'mode': 'live',
                'source': 'upload',
              },
            ],
          ),
          title: 'Preflight Note',
          revision: 1,
          createdAt: now,
          updatedAt: now,
          syncState: LocalSyncState.local,
          accountId: null,
        );
        final pairedTyped = LocalNote(
          id: 'n_pre__typed',
          schema: _typedSchema,
          document: _typedDoc(),
          title: 'Preflight Note',
          revision: 1,
          createdAt: now,
          updatedAt: now,
          syncState: LocalSyncState.local,
          accountId: null,
        );
        final missingStore = _MissingFileStore(pairedTyped);

        for (final locale in ['en', 'pt-BR', 'th']) {
          for (final brightness in [Brightness.light, Brightness.dark]) {
            for (final size in [const Size(1280, 800), const Size(390, 844)]) {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = size;
              addTearDown(tester.view.reset);

              var shouldFail = true;
              final handler = ExportHandler(
                note: missingFilesNote,
                store: missingStore,
                renderPages: (_, _) async {
                  if (shouldFail) throw StateError('render error');
                  return [await _solidImage()];
                },
                saveLocation: (_) async => '${root.path}/out_denied/f.zip',
              )..mode = PdfExportMode.both;
              addTearDown(handler.dispose);

              await tester.pumpWidget(
                _host(
                  ExportDialog(key: ValueKey(handler), handler: handler),
                  brightness: brightness,
                  locale: locale,
                ),
              );
              await _pumpUntil(
                tester,
                () => find
                    .byKey(const Key('export-preflight'))
                    .evaluate()
                    .isNotEmpty,
              );

              expect(
                tester.takeException(),
                isNull,
                reason: '$locale ${brightness.name} $size preflight',
              );
              expect(find.byKey(const Key('export-preflight')), findsOneWidget);
              expect(
                find.byKey(const Key('export-preflight-list')),
                findsOneWidget,
              );
              expect(
                handler.preflight!.issues.map((i) => i.kind),
                contains('failed_chart'),
              );
              expect(find.byKey(const Key('export-private')), findsOneWidget);
              expect(
                handler.stage,
                ExportStage.preflight,
                reason: 'Save must stay disabled in preflight stage',
              );
              expect(
                tester
                    .widget<AppButton>(find.byKey(const Key('export-save')))
                    .onPressed,
                isNull,
              );

              // Continue with placeholders -> hits render error -> shows Retry.
              await tester.tap(find.byKey(const Key('export-continue')));
              await _pumpUntil(
                tester,
                () => find
                    .byKey(const Key('export-failed'))
                    .evaluate()
                    .isNotEmpty,
              );
              expect(tester.takeException(), isNull);
              expect(find.byKey(const Key('export-failed')), findsOneWidget);
              expect(
                find.byKey(const Key('export-failed-retry')),
                findsOneWidget,
              );

              // Retry now builds placeholders -> ready -> triggers write failure banner.
              shouldFail = false;
              await tester.tap(find.byKey(const Key('export-failed-retry')));
              await _pumpUntil(
                tester,
                () =>
                    find.byKey(const Key('export-count')).evaluate().isNotEmpty,
              );
              expect(tester.takeException(), isNull);
              expect(find.byKey(const Key('export-count')), findsOneWidget);

              await tester.tap(find.byKey(const Key('export-save')));
              await _pumpUntil(
                tester,
                () => find
                    .byKey(const Key('export-save-error'))
                    .evaluate()
                    .isNotEmpty,
              );
              expect(tester.takeException(), isNull);
              expect(
                find.byKey(const Key('export-save-error')),
                findsOneWidget,
              );
            }
          }
        }
      },
    );
  });
}
