import 'package:annotations_shared/domain/models/reports_card_reference.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/models/reports_embed_data.dart';
import 'package:annotations_shared/dal/remote/api_adapter.dart';
import 'package:annotations_shared/domain/services/annotations_service.dart';
import 'package:annotations_shared/domain/services/preferences.dart';
import 'package:annotations_shared/domain/services/task_card_service.dart';
import 'package:annotations_shared/domain/services/reports_embed_source.dart';
import 'package:annotations_shared/dal/remote/reports_api_adapter.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/note_embedded_cards_layer.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'package:annotations_shared/presentation/frontend/components/reports_embed_card.dart';
import 'package:annotations_shared/presentation/frontend/components/scope.dart';
import 'package:annotations_shared/presentation/frontend/components/task_card_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:reports_view/reports_view.dart';

const _dataset = {
  'dataset_id': 'monthly',
  'title': 'Monthly',
  'can_view': true,
  'fields': [
    {'name': 'month', 'type': 'string', 'role': 'dimension'},
    {'name': 'sales', 'type': 'integer', 'role': 'measure'},
  ],
  'rows': [
    {'month': 'Jan', 'sales': 11},
  ],
  'offset': 0,
  'limit': 5000,
  'total_rows': 1,
  'lineage': {
    'calculation_id': 'monthly-sales',
    'calculation_version': 3,
    'calculated_at': '2026-11-24T00:00:00Z',
  },
};

Widget _host(Widget child, {String locale = 'en'}) {
  final preferences = Preferences()..locale = locale;
  return AppScope(
    preferences: preferences,
    service: AnnotationsService(
      api: ApiAdapter(
        client: MockClient((_) async => throw StateError('unused')),
      ),
    ),
    child: MaterialApp(
      locale: Locale(locale),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('Reports card fits the authorized chart in its card bounds', (
    tester,
  ) async {
    final page = DatasetPage.fromJson(_dataset);
    await tester.binding.setSurfaceSize(const Size(420, 320));
    await tester.pumpWidget(
      _host(
        ReportsEmbedCard(
          data: ReportsEmbedData(
            state: ReportsEmbedState.readable,
            reference: const ReportsCardReference(
              project: 'public',
              report: 'sales',
              dataset: 'monthly',
            ),
            descriptor: page.descriptor,
            page: page,
            openInReportsUrl: 'https://reports.asodya.com/v1/menu/public/sales',
          ),
          loading: false,
          snapshot: false,
          onOpen: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.byKey(const Key('reports-open-in-reports')), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
    'restricted Reports state never reveals private titles or values',
    (tester) async {
      final page = DatasetPage.fromJson(_dataset);
      final report = ReportView.fromJson({
        'project': 'private-project',
        'report': 'private-report',
        'title': 'SECRET REPORT TITLE',
        'description': 'SECRET DESCRIPTION',
        'datasets': [_dataset],
      });
      await tester.pumpWidget(
        _host(
          ReportsEmbedCard(
            data: ReportsEmbedData(
              state: ReportsEmbedState.restricted,
              reference: null,
              reportView: report,
              descriptor: page.descriptor,
              page: page,
            ),
            loading: false,
            snapshot: true,
            onRetry: () {},
          ),
          locale: 'pt-BR',
        ),
      );
      expect(find.text('Este relatório tem acesso restrito.'), findsOneWidget);
      expect(find.text('SECRET REPORT TITLE'), findsNothing);
      expect(find.text('SECRET DESCRIPTION'), findsNothing);
      expect(find.text('11'), findsNothing);
      expect(find.byKey(const Key('reports-retry')), findsNothing);
    },
  );

  testWidgets(
    'public paper embed layer does not fetch private reports or tasks',
    (tester) async {
      var reportRequests = 0;
      var taskRequests = 0;
      final source = ReportsEmbedSource(
        api: ReportsApiAdapter(
          client: MockClient((_) async {
            reportRequests++;
            return http.Response('{}', 500);
          }),
          headersProvider: ({required mutation}) async => const {},
        ),
      );
      final document = NoteDocument.fromJson({
        'page': {
          'width': 1000,
          'background': {'kind': 'blank'},
        },
        'items': [
          {
            'id': 'private-report',
            'kind': 'reports_embed',
            'x': 20,
            'y': 20,
            'width': 300,
            'height': 160,
            'report_id': 'secret-report',
            'project_slug': 'private-project',
            'report_slug': 'secret-report',
            'dataset_id': 'dataset-1',
            'mode': 'live',
            'source': 'link',
          },
          {
            'id': 'private-task',
            'kind': 'task_card',
            'x': 20,
            'y': 200,
            'width': 300,
            'height': 120,
            'task_id': 'private-task-id',
          },
        ],
      }, schema: DocumentSchema('note-original', 1));
      const view = PaperView(
        zoom: 1,
        scroll: Offset.zero,
        size: Size(500, 500),
      );
      final preferences = Preferences()..locale = 'en';
      await tester.pumpWidget(
        AppScope(
          preferences: preferences,
          service: AnnotationsService(
            api: ApiAdapter(
              client: MockClient(
                (_) async => throw StateError('unused app API'),
              ),
            ),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: NoteEmbeddedCardsLayer(
                document: document,
                view: view,
                reportsSource: source,
                publicProjection: true,
                loadTask: (_) async {
                  taskRequests++;
                  return TaskSummary.fromJson({
                    'task_id': 'private-task-id',
                    'title': 'SECRET TASK',
                    'status': 'open',
                  });
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(reportRequests, 0);
      expect(taskRequests, 0);
      expect(find.text('This report is restricted.'), findsOneWidget);
      expect(find.text('Task is restricted.'), findsOneWidget);
      expect(find.text('secret-report'), findsNothing);
      expect(find.text('SECRET TASK'), findsNothing);
    },
  );

  testWidgets('task card grows downward and keeps all fields at narrow width', (
    tester,
  ) async {
    final task = TaskSummary.fromJson({
      'task_id': 'task-1',
      'title': 'Prepare the complete field report before the review meeting',
      'description':
          'Compare the source rows, add the method, and record the limits.',
      'due_date': '2026-11-30',
      'status': 'open',
    });

    await tester.binding.setSurfaceSize(const Size(600, 1000));
    await tester.pumpWidget(
      _host(const SizedBox(width: 500, child: TaskCardView(task: null))),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 500,
          child: TaskCardView(key: const Key('task-wide'), task: task),
        ),
      ),
    );
    final wideHeight = tester
        .getSize(find.byKey(const Key('task-wide')))
        .height;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 180,
          child: TaskCardView(key: const Key('task-narrow'), task: task),
        ),
      ),
    );
    final narrowHeight = tester
        .getSize(find.byKey(const Key('task-narrow')))
        .height;
    expect(narrowHeight, greaterThan(wideHeight));
    expect(find.text(task.title), findsOneWidget);
    expect(find.text(task.description!), findsOneWidget);
    expect(find.textContaining('2026-11-30'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('restricted task placeholder hides cached task details', (
    tester,
  ) async {
    final task = TaskSummary.fromJson({
      'task_id': 'task-1',
      'title': 'SECRET TASK TITLE',
      'description': 'SECRET TASK BODY',
      'status': 'open',
    });
    await tester.pumpWidget(
      _host(
        TaskCardView(task: task, restricted: true, onRetry: () {}),
        locale: 'th',
      ),
    );
    expect(find.text('งานนี้จำกัดสิทธิ์การเข้าถึง'), findsOneWidget);
    expect(find.text('SECRET TASK TITLE'), findsNothing);
    expect(find.text('SECRET TASK BODY'), findsNothing);
    expect(find.byKey(const Key('task-retry')), findsNothing);
  });
}
