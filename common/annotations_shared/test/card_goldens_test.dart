// annotations#34: every card and every width level (B3 option B), in EN,
// pt-BR and TH, light and dark.
import 'dart:io';

import 'package:annotations_shared/dal/local/quill_text_engine.dart';
import 'package:annotations_shared/presentation/frontend/components/card_layout.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/components/tokens.dart';
import 'package:annotations_shared/presentation/frontend/handlers/attachment_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attachment_fixtures.dart';
import 'design_goldens_test.dart' show loadAppFonts;

const texts = {
  'en': (
    title: 'How plants turn light into sugar',
    description:
        'A short guide to photosynthesis with diagrams and a quiz at the end.',
    link: 'Photosynthesis basics for the first exam',
    video: 'Photosynthesis in five minutes',
    file: 'Lab report on bean growth.docx',
  ),
  'pt-BR': (
    title: 'Como as plantas transformam luz em açúcar',
    description:
        'Um guia curto sobre fotossíntese com diagramas e um quiz no final.',
    link: 'Fotossíntese básica para a primeira prova',
    video: 'Fotossíntese em cinco minutos',
    file: 'Relatório de laboratório sobre o feijão.docx',
  ),
  'th': (
    title: 'พืชเปลี่ยนแสงเป็นน้ำตาลได้อย่างไร',
    description:
        'คู่มือสั้น ๆ เรื่องการสังเคราะห์แสง พร้อมแผนภาพและแบบทดสอบท้ายบท',
    link: 'พื้นฐานการสังเคราะห์แสงสำหรับการสอบครั้งแรก',
    video: 'การสังเคราะห์แสงในห้านาที',
    file: 'รายงานการทดลองการเจริญเติบโตของถั่ว.docx',
  ),
};

void main() {
  setUpAll(loadAppFonts);

  for (final (mode, brightness) in const [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    for (final locale in texts.keys) {
      testWidgets('card levels, $mode, $locale', (tester) async {
        final t = texts[locale]!;
        final store = FileStore();
        store.put(
          previewPng,
          name: 'preview.png',
          type: 'image/png',
          id: 'pic',
        );
        store.put(csvBytes, name: 'plants.csv', type: 'text/csv', id: 'csv');
        store.put(
          pdfBytes,
          name: 'chapter-3.pdf',
          type: 'application/pdf',
          id: 'pdf',
        );
        store.put(
          csvBytes,
          name: t.file,
          type: 'application/msword',
          id: 'doc',
        );
        final files = AttachmentCache(store);
        addTearDown(files.dispose);
        for (final id in ['pic', 'csv', 'pdf', 'doc']) {
          files
            ..info(id)
            ..image(id)
            ..csv(id)
            ..pdf(id);
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        final website = <String, Object?>{
          'kind': 'website_card',
          'url': 'https://biology.example.org/light',
          'title': t.title,
          'description': t.description,
          'site_name': 'biology.example.org',
          'preview_file_id': 'pic',
        };
        final youtube = <String, Object?>{
          'kind': 'youtube_card',
          'url': 'https://www.youtube.com/watch?v=abc',
          'title': t.video,
          'preview_file_id': 'pic',
        };
        final link = <String, Object?>{
          'kind': 'link_card',
          'url': 'https://school.example.org/exam',
          'title': t.link,
        };
        final file = <String, Object?>{'kind': 'file_card', 'file_id': 'doc'};
        final cases = <(String, Map<String, Object?>, double, double?)>[
          ('website, picture left', website, 480, null),
          ('website, picture on top', website, 320, null),
          ('website, no picture', website, 200, null),
          (
            'website without a picture',
            {...website}..remove('preview_file_id'),
            480,
            null,
          ),
          ('YouTube, picture left', youtube, 480, null),
          ('YouTube, picture on top', youtube, 320, null),
          ('YouTube, no picture', youtube, 200, null),
          ('link', link, 320, null),
          ('link, narrow', link, 160, null),
          ('file', file, 320, null),
          ('file, narrow', file, 160, null),
          ('CSV table', {'kind': 'csv_table', 'file_id': 'csv'}, 400, 160),
          (
            'PDF',
            {'kind': 'pdf_preview', 'file_id': 'pdf'},
            160,
            160 * 842 / 595,
          ),
          ('picture', {'kind': 'image', 'file_id': 'pic'}, 240, 135),
        ];
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 1500);
        addTearDown(tester.view.reset);
        final colors = brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light;
        final style = CardStyle(text: annotationsTextStyle, colors: colors);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(brightness),
            home: Material(
              color: colors.page,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 16,
                  children: [
                    for (final (name, item, width, height) in cases)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$name (${width.round()})',
                            style: TextStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _Card(
                            item: item,
                            width: width,
                            height:
                                height ??
                                measureCard(item, width, style, files)!,
                            style: style,
                            files: files,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/cards/card_levels_${mode}_$locale.png'),
        );
        final review = Platform.environment['ANNOTATIONS_REVIEW_DIR'];
        if (review != null) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('$review/card_levels_${mode}_$locale.png'),
          );
        }
      });
    }
  }

  test('a taller wrapping card keeps its text: narrower is taller', () {
    final style = CardStyle(
      text: annotationsTextStyle,
      colors: AppColors.light,
    );
    final link = <String, Object?>{
      'kind': 'link_card',
      'url': 'https://school.example.org/exam',
      'title': texts['en']!.link,
    };
    expect(
      measureCard(link, 160, style, null)!,
      greaterThan(measureCard(link, 480, style, null)!),
    );
    expect(measureCard({'kind': 'image'}, 200, style, null), isNull);
  });
}

class _Card extends StatelessWidget {
  final Map<String, Object?> item;
  final double width, height;
  final CardStyle style;
  final AttachmentCache files;
  const _Card({
    required this.item,
    required this.width,
    required this.height,
    required this.style,
    required this.files,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, height),
    painter: _Painter(item, style, files),
  );
}

class _Painter extends CustomPainter {
  _Painter(this.item, this.style, this.files);
  final Map<String, Object?> item;
  final CardStyle style;
  final AttachmentCache files;

  @override
  void paint(Canvas canvas, Size size) {
    final card = CardLayout(item, size.width, style, files);
    card.paint(canvas, Offset.zero & size);
    card.dispose();
  }

  @override
  bool shouldRepaint(_Painter old) => false;
}
