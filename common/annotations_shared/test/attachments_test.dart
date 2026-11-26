// annotations#34: adding files and links, copy jobs, the card actions, and
// the card content helpers (B9).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/services/card_content.dart';
import 'package:annotations_shared/domain/services/note_history.dart';
import 'package:annotations_shared/domain/services/object_selection.dart';
import 'package:annotations_shared/presentation/frontend/handlers/attachment_cache.dart';
import 'package:annotations_shared/presentation/frontend/handlers/attachment_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/handlers/pdf_page_renderer.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attachment_fixtures.dart';
import 'design_goldens_test.dart' show loadAppFonts;
import 'paper_canvas_test.dart' show desktop, host, setWindow, studyNote;
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/core/local_store_settings.dart';

Map<String, Object?>? item(PaperHandler h, String id) {
  for (final it in (h.document as PaperDocument).itemsJson) {
    if (it['id'] == id) return it;
  }
  return null;
}

List<Map<String, Object?>> cards(PaperHandler h, String kind) => [
  for (final it in (h.document as PaperDocument).itemsJson)
    if (it['kind'] == kind) it,
];

void main() {
  late Directory pdfCache;
  setUpAll(() async {
    pdfCache = usePdfiumInTests();
    await loadAppFonts();
  });
  tearDownAll(() => pdfCache.deleteSync(recursive: true));
  // These tests place PDF cards without waiting for PDFium, whose answer
  // comes outside the fake clock (pdf_page_test.dart covers drawing).
  setUp(() => AttachmentCache.defaultPdfPageRenderer = (_, _) async => null);
  tearDown(() => AttachmentCache.defaultPdfPageRenderer = renderFirstPdfPage);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('card content', () {
    test('kinds and media types', () {
      expect(cardKindFor('image/png'), 'image');
      expect(cardKindFor('text/csv'), 'csv_table');
      expect(cardKindFor('application/pdf'), 'pdf_preview');
      expect(cardKindFor('application/zip'), 'file_card');
      expect(mediaTypeFor('Report.PDF'), 'application/pdf');
      expect(mediaTypeFor('notes'), 'application/octet-stream');
      expect(fileTypeLabel('lab.docx', 'x'), 'DOCX');
      expect(formatFileSize(999), '999 B');
      expect(formatFileSize(1536), '1.5 KB');
      expect(formatFileSize(5 * 1024 * 1024), '5.0 MB');
    });

    test('CSV with quotes, commas and line breaks', () {
      final rows = parseCsv('a,"b, c","d ""e"""\r\n1,"two\nlines",3');
      expect(rows, [
        ['a', 'b, c', 'd "e"'],
        ['1', 'two\nlines', '3'],
      ]);
      expect(parseCsv('x\n' * 900, maxRows: 500), hasLength(500));
    });

    test('PDF page shape, turned pages and page count', () {
      final info = pdfInfo(pdfBytes)!;
      expect((info.width, info.height, info.pages), (595.0, 842.0, 2));
      final turned = pdfInfo(
        latin1.encode(
          '%PDF-1.7 /Type /Page /MediaBox [0 0 595 842] /Rotate 90',
        ),
      )!;
      expect(turned.width, 842);
      expect(pdfInfo(csvBytes), isNull);
    });

    test('links', () {
      expect(
        webLink(' https://example.org/a?b=1 '),
        'https://example.org/a?b=1',
      );
      expect(webLink('example.org'), isNull);
      expect(webLink('see https://example.org'), isNull);
      expect(webLink('ftp://example.org'), isNull);
      expect(webLink('https://user@example.org'), isNull);
      expect(isYoutubeUrl('https://youtu.be/abc'), isTrue);
      expect(isYoutubeUrl('https://example.org/youtube.com'), isFalse);
      expect(siteOf('https://www.example.org/x'), 'example.org');
    });
  });

  group('on paper', () {
    late Directory dir;
    late FileStore store;
    late PaperHandler paper;
    late AttachmentHandler files;
    final launched = <Uri>[];
    var picks = <XFile>[];

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('attachments_');
      store = FileStore();
      launched.clear();
      picks = [];
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String file(String name, List<int> bytes) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return f.path;
    }

    Future<void> open(
      WidgetTester tester, {
      NoteDocument? document,
      LinkPreviewSource? preview,
      Brightness brightness = Brightness.light,
    }) async {
      await setWindow(tester, desktop);
      paper = PaperHandler(
        noteId: 'n1',
        document: document ?? studyNote(),
        autosave: NoteAutosave(
          store,
          settings: const LocalStoreSettings(
            autosaveDelay: Duration(milliseconds: 20),
          ),
        ),
      );
      addTearDown(paper.dispose);
      var ids = 0;
      files = AttachmentHandler(
        paper: paper,
        preview: preview,
        newId: () => 'card${ids++}',
        pickFiles: () async => picks,
        launch: (uri) async {
          launched.add(uri);
          return true;
        },
        saveLocation: (name) async => '${dir.path}/saved-$name',
      );
      addTearDown(files.dispose);
      await tester.pumpWidget(
        host(
          PaperScreen(handler: paper, attachments: files),
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Waits for the running copies (real file reads and picture decoding
    /// take real time, longer under load).
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (files.jobs.value.every(
          (j) => j.state == AttachmentJobState.failed,
        )) {
          break;
        }
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('structured report cards use snapped free-space placement', (
      tester,
    ) async {
      final baseDocument = studyNote();
      final documentJson = baseDocument.toJson();
      final items = documentJson['items'] as List;
      final measuredText = Map<String, Object?>.from(items.first as Map)
        ..['x'] = 24
        ..['y'] = 24
        ..['width'] = 360
        ..['height'] = 65;
      items[0] = measuredText;
      await open(
        tester,
        document: NoteDocument.fromJson(
          documentJson,
          schema: baseDocument.schema,
        ),
      );

      expect(
        files.addStructuredCard({
          'id': 'reports-card',
          'kind': 'reports_embed',
          'width': 360,
          'height': 224,
          'report_id': 'sales',
          'project_slug': 'public',
          'report_slug': 'sales',
          'dataset_id': 'monthly',
          'mode': 'live',
          'source': 'link',
        }),
        isTrue,
      );
      await paper.autosave.flush();
      final card = cards(paper, 'reports_embed').single;
      expect((card['x'] as num) % 8, 0);
      expect((card['y'] as num) % 8, 0);
      expect(card['y'], greaterThan(24));
      expect(cards(paper, 'text').first['height'], 65);
    });

    testWidgets('a picked file shows its copy job, then its card in free '
        'space; pictures keep their shape', (tester) async {
      await open(tester);
      store.hold = Completer<void>();
      picks = [
        XFile(file('lab.docx', utf8.encode('report'))),
        XFile(file('photo.png', previewPng)),
      ];
      await files.pick(at: const Offset(600, 300));
      await tester.pump();
      // Never ready before the copy is there (B9.6).
      expect(find.text('Copying lab.docx'), findsOneWidget);
      expect(cards(paper, 'file_card'), isEmpty);
      store.hold!.complete();
      store.hold = null;
      await settle(tester);
      expect(find.text('Copying lab.docx'), findsNothing);
      final card = cards(paper, 'file_card').single;
      // Placed below the picture that was at the drop point, on the grid.
      expect((card['y'] as num) % 8, 0);
      expect(card['height'], greaterThan(40));
      final picture = cards(
        paper,
        'image',
      ).firstWhere((i) => i['file_id'] != 'file-image-1');
      expect(
        (picture['height'] as num) / (picture['width'] as num),
        closeTo(18 / 32, 0.01),
      );
      // The local note uploads nothing: the store only copied (B9.7).
      expect(store.files, hasLength(2));
    });

    testWidgets('a failed copy offers Retry and Cancel; Cancel adds nothing', (
      tester,
    ) async {
      await open(tester);
      store.fail = 1;
      picks = [XFile(file('a.csv', csvBytes))];
      await files.pick(at: const Offset(40, 600));
      await settle(tester);
      expect(find.text('Could not add a.csv'), findsOneWidget);
      await tester.tap(find.byKey(const Key('job-retry')));
      await settle(tester);
      expect(cards(paper, 'csv_table'), hasLength(1));
      store.fail = 1;
      picks = [XFile(file('b.csv', csvBytes))];
      await files.pick(at: const Offset(40, 500));
      await settle(tester);
      await tester.tap(find.byKey(const Key('job-cancel')));
      await tester.pump();
      expect(find.text('Could not add b.csv'), findsNothing);
      expect(cards(paper, 'csv_table'), hasLength(1));
    });

    testWidgets('Remove asks first, keeps the file on the computer, and Undo '
        'brings the card back', (tester) async {
      await open(tester);
      final original = file('notes.pdf', pdfBytes);
      picks = [XFile(original)];
      await files.pick(at: const Offset(40, 600));
      await settle(tester);
      final id = cards(paper, 'pdf_preview').single['id'] as String;
      paper.select(ObjectSelection([id]));
      await tester.pump();
      await tester.tap(find.byKey(const Key('card-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('card-remove')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remove-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-confirm')));
      await tester.pumpAndSettle();
      expect(item(paper, id), isNull);
      expect(File(original).existsSync(), isTrue);
      paper.undo();
      await tester.pump();
      expect(item(paper, id), isNotNull);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Replace keeps the place and size; a failure keeps the '
        'original; Open and Save a copy use the stored file', (tester) async {
      await open(tester);
      picks = [XFile(file('first.docx', utf8.encode('one')))];
      await files.pick(at: const Offset(40, 600));
      await settle(tester);
      final before = cards(paper, 'file_card').single;
      final id = before['id'] as String;
      picks = [XFile(file('second.pdf', pdfBytes))];
      await files.replace(id);
      await settle(tester);
      final after = item(paper, id)!;
      expect(after['kind'], 'pdf_preview');
      for (final k in ['x', 'y', 'width', 'height']) {
        expect(after[k], before[k], reason: k);
      }
      store.fail = 1;
      picks = [XFile(file('third.docx', utf8.encode('three')))];
      await files.replace(id);
      await settle(tester);
      expect(item(paper, id)!['file_id'], after['file_id']);
      await files.open(id);
      expect(launched.single.scheme, 'file');
      expect(await tester.runAsync(() => files.saveCopy(id)), isTrue);
      expect(File('${dir.path}/saved-second.pdf').existsSync(), isTrue);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('links: link, YouTube and website cards; Edit link that '
        'would overlap a block is rejected', (tester) async {
      await open(
        tester,
        preview: (url) async => url.contains('long')
            ? {'title': 'A very long title ' * 12, 'site_name': 'Example'}
            : {
                'title': 'Light and sugar',
                'description': 'A guide.',
                'site_name': 'Biology',
              },
      );
      expect(
        await files.addLink('https://youtu.be/abc', at: const Offset(40, 600)),
        isTrue,
      );
      expect(cards(paper, 'youtube_card'), hasLength(1));
      expect(
        await files.addLink(
          'https://bio.example.org/a',
          at: const Offset(40, 800),
        ),
        isTrue,
      );
      final site = cards(paper, 'website_card').single;
      expect(site['title'], 'Light and sugar');
      expect(await files.addLink('not a link'), isFalse);
      // A card right above another block cannot grow into it (type C).
      final id = site['id'] as String;
      final y = (site['y'] as num) + (site['height'] as num);
      final blocker = {
        'id': 'below',
        'kind': 'text',
        'x': site['x'],
        'y': ((y / 8).ceil() * 8),
        'width': 200,
        'height': 40,
        'spans': [
          {'text': 'Below'},
        ],
      };
      paper.apply(
        HistoryCommand(CommandKind.card),
        (rules, d) => rules.check(d, {'op': 'add', 'item': blocker}),
      );
      expect(await files.editLink(id, 'https://long.example.org'), isFalse);
      expect(item(paper, id)!['url'], 'https://bio.example.org/a');
      expect(await files.editLink(id, 'https://other.example.org'), isTrue);
      expect(item(paper, id)!['url'], 'https://other.example.org');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a wheel over a CSV table scrolls the table, not the page', (
      tester,
    ) async {
      await open(tester);
      picks = [XFile(file('plants.csv', csvBytes))];
      await files.pick(at: const Offset(40, 600));
      await settle(tester);
      final table = cards(paper, 'csv_table').single;
      // Make the table short, so it has rows to scroll.
      paper.apply(
        HistoryCommand(CommandKind.card),
        (rules, d) => rules.check(d, {
          'op': 'update',
          'id': table['id'],
          'changes': {'height': 64},
        }),
      );
      await tester.pump();
      final view = paper.view.value!;
      final over = view.toScreen(
        Offset((table['x'] as num) + 20.0, (table['y'] as num) + 20.0),
      );
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(over));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.pump();
      expect(paper.view.value, view);
      expect(paper.files.tableScroll(table['id'] as String).dy, greaterThan(0));
      await tester.pump(const Duration(seconds: 1));
    });

    final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
    for (final (mode, brightness) in const [
      ('light', Brightness.light),
      ('dark', Brightness.dark),
    ]) {
      testWidgets('review images, $mode', skip: review == null, (tester) async {
        AttachmentCache.defaultPdfPageRenderer = renderFirstPdfPage;
        Future<void> shot(String name) => expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('$review/attachments_${name}_$mode.png'),
        );
        await open(
          tester,
          brightness: brightness,
          preview: (url) async => {
            'title': 'How plants turn light into sugar',
            'description': 'A short guide with diagrams and a quiz.',
            'site_name': 'biology.example.org',
          },
        );
        await tester.tap(find.byKey(const Key('add-menu')));
        await tester.pumpAndSettle();
        await shot('add_menu');
        await tester.tapAt(const Offset(20, 400));
        await tester.pumpAndSettle();
        picks = [
          XFile(file('Lab report.docx', utf8.encode('report'))),
          XFile(file('plants.csv', csvBytes)),
          XFile(file('chapter-3.pdf', drawablePdfBytes)),
        ];
        await files.pick(at: const Offset(40, 360));
        await settle(tester);
        // Wait for PDFium to draw the PDF card's first page.
        final pdf = cards(paper, 'pdf_preview').single['file_id'] as String;
        for (var i = 0; i < 200 && paper.files.image(pdf) == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(paper.files.image(pdf), isNotNull);
        await files.addLink(
          'https://www.youtube.com/watch?v=x',
          at: const Offset(40, 560),
        );
        await files.addLink(
          'https://bio.example.org/a',
          at: const Offset(520, 560),
        );
        await settle(tester);
        paper.select(ObjectSelection.empty);
        await tester.pump();
        await shot('cards');
        final doc = cards(paper, 'file_card').single['id'] as String;
        paper.select(ObjectSelection([doc]));
        await tester.pump();
        await tester.tap(find.byKey(const Key('card-menu')));
        await tester.pumpAndSettle();
        await shot('file_menu');
        await tester.tap(find.byKey(const Key('card-remove')));
        await tester.pumpAndSettle();
        await shot('remove_dialog');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        final link = cards(paper, 'youtube_card').single['id'] as String;
        paper.select(ObjectSelection([link]));
        await tester.pump();
        await tester.tap(find.byKey(const Key('card-menu')));
        await tester.pumpAndSettle();
        await shot('link_menu');
        await tester.tapAt(const Offset(20, 400));
        await tester.pumpAndSettle();
        paper.select(ObjectSelection.empty);
        store.hold = Completer<void>();
        picks = [XFile(file('photo.png', previewPng))];
        await files.pick(at: const Offset(720, 600));
        await tester.pump();
        await shot('job_copying');
        store.fail = 1;
        store.hold!.complete();
        store.hold = null;
        await settle(tester);
        await shot('job_failed');
        await tester.tap(find.byKey(const Key('job-cancel')));
        await tester.pump(const Duration(seconds: 1));
      });
    }
  });
}
