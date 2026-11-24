import 'package:flutter_test/flutter_test.dart';
import 'package:annotations_shared/domain/models/reports_card_reference.dart';

void main() {
  group('ReportsCardReference', () {
    test('parses the Reports source URL and drops filter query values', () {
      final ref = ReportsCardReference.tryParse(
        'https://reports.asodya.com/v1/menu/annotations/report-1/primary?f.email=private&lang=th',
      );

      expect(ref, isNotNull);
      expect(ref!.project, 'annotations');
      expect(ref.report, 'report-1');
      expect(ref.dataset, 'primary');
      expect(
        ref.sourceUrl,
        'https://reports.asodya.com/v1/menu/annotations/report-1/primary',
      );
      expect(
        ref.datasetPath,
        '/projects/annotations/reports/report-1/datasets/primary',
      );
      expect(
        ref.viewerEmbedPath,
        '/projects/annotations/reports/report-1/cards/primary/embed',
      );
    });

    test('parses the exact relative owner item embed path', () {
      expect(
        ReportsCardReference.tryParse(
          '/projects/annotations/showcase/user-report/cards/primary/embed',
        ),
        const ReportsCardReference(
          project: 'annotations',
          report: 'user-report',
          dataset: 'primary',
        ),
      );
    });

    test('parses the Reports generated public embed URL', () {
      expect(
        ReportsCardReference.tryParse(
          'https://reports.asodya.com/v1/embed/annotations/report-1/primary',
        ),
        const ReportsCardReference(
          project: 'annotations',
          report: 'report-1',
          dataset: 'primary',
        ),
      );
    });

    test('rejects untrusted hosts, schemes, path shapes and malformed IDs', () {
      for (final value in [
        'http://reports.asodya.com/v1/menu/annotations/report-1/card-1',
        'https://reports.asodya.com.evil.test/v1/menu/annotations/report-1/card-1',
        'https://user@reports.asodya.com/v1/menu/annotations/report-1/card-1',
        'https://reports.asodya.com:443/v1/menu/annotations/report-1/card-1',
        'https://reports.asodya.com/v1/menu/annotations/report-1/card-1/extra',
        'https://reports.asodya.com/v1/menu/Aa/report-1/card-1',
        'https://reports.asodya.com/v1/menu/a/report-1/card-1',
        '/projects/a/reports/b/datasets/c',
        '/projects/a/showcase/../cards/c/embed',
        'report-42',
      ]) {
        expect(ReportsCardReference.tryParse(value), isNull, reason: value);
      }
    });
  });
}
