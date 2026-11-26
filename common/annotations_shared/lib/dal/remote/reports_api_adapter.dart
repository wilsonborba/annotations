import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:reports_view/reports_view.dart';

import '../../core/settings.dart';
import '../../domain/models/reports_card_reference.dart';
import '../../domain/services/native_auth_service.dart';
import 'api_adapter.dart';
import 'reports_http_client.dart';

typedef ReportsHeadersProvider =
    Future<Map<String, String>> Function({required bool mutation});

/// Reports session and owner APIs. Every session operation goes through the
/// configured Asodya gateway base and uses the gateway's existing cookie/CSRF
/// identity; this adapter never sends an owner id in a body.
final class ReportsApiAdapter {
  ReportsApiAdapter({
    required this.headersProvider,
    http.Client? client,
    ApiAdapter? api,
  }) : api =
           api ??
           ApiAdapter(
             client: client ?? createReportsHttpClient(),
             base: reportsApiBase(Settings.current.apiBase),
           );

  final ApiAdapter api;
  final ReportsHeadersProvider headersProvider;

  static Map<String, String> browserSessionHeaders({required bool mutation}) =>
      browserReportsHeaders(mutation: mutation);

  static ReportsHeadersProvider nativeSessionHeaders(NativeAuthService auth) =>
      ({required bool mutation}) async {
        final session = await auth.storage.readSession();
        return session?.authHeaders(isMutation: mutation) ?? const {};
      };

  static String reportsApiBase(String annotationsApiBase) {
    final source = Uri.parse(annotationsApiBase);
    return Uri(
      scheme: source.scheme,
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/apps/reports/v1',
    ).toString();
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic>? body, {
    required ReportsViewerSession session,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    final headers = Map<String, String>.from(
      await headersProvider(mutation: true),
    );
    final caller = await api.request('/me', headers: headers);
    if (caller['user_id'] != session.userId) {
      throw const ReportsSessionChangedException();
    }
    if (idempotencyKey != null && idempotencyKey.trim().isNotEmpty) {
      headers['idempotency-key'] = idempotencyKey;
    }
    return api.request(
      path,
      method: 'POST',
      body: body,
      query: query,
      headers: headers,
    );
  }

  Future<ReportsViewerSession> viewerSession() async {
    final headers = await headersProvider(mutation: false);
    final result = await api.request('/me', headers: headers);
    final userId = result['user_id'];
    if (userId is! String || userId.trim().isEmpty) {
      throw const ReportsSessionException();
    }
    return ReportsViewerSession._(userId: userId, headers: headers);
  }

  Future<Map<String, dynamic>> searchReports(
    ReportsViewerSession session, {
    required String project,
    String? query,
    String? tier,
    String language = 'en',
    int page = 1,
    int pageSize = 12,
  }) => api.request(
    '/me/projects/${Uri.encodeComponent(project)}/reports',
    query: {
      'page': '$page',
      'page_size': '${pageSize.clamp(1, 100)}',
      'lang': language,
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      if (tier != null && tier.isNotEmpty) 'tier': tier,
    },
    headers: session.headers,
  );

  Future<ReportView> reportView(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
  }) async {
    final data = await reportViewJson(session, reference, language: language);
    return ReportView.fromJson(data);
  }

  Future<Map<String, dynamic>> reportViewJson(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
  }) => reportViewForJson(
    session,
    project: reference.project,
    report: reference.report,
    language: language,
  );

  Future<ReportView> reportViewFor(
    ReportsViewerSession session, {
    required String project,
    required String report,
    String language = 'en',
  }) async => ReportView.fromJson(
    await reportViewForJson(
      session,
      project: project,
      report: report,
      language: language,
    ),
  );

  Future<Map<String, dynamic>> reportViewForJson(
    ReportsViewerSession session, {
    required String project,
    required String report,
    String language = 'en',
  }) => api.request(
    '/projects/${Uri.encodeComponent(project)}/reports/${Uri.encodeComponent(report)}',
    query: {'lang': language},
    headers: session.headers,
  );

  Future<DatasetPage> datasetPage(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
    int offset = 0,
    int limit = 5000,
  }) async {
    final data = await datasetPageJson(
      session,
      reference,
      language: language,
      offset: offset,
      limit: limit,
    );
    return DatasetPage.fromJson(data);
  }

  Future<Map<String, dynamic>> datasetPageJson(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
    int offset = 0,
    int limit = 5000,
  }) => api.request(
    reference.datasetPath,
    query: {
      'lang': language,
      'offset': '$offset',
      'limit': '${limit.clamp(1, 5000)}',
    },
    headers: session.headers,
  );

  Future<Map<String, dynamic>> viewerEmbed(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
  }) => api.request(
    reference.viewerEmbedPath,
    query: {'lang': language},
    headers: session.headers,
  );

  Future<Map<String, dynamic>> captureSnapshot(
    ReportsViewerSession session,
    ReportsCardReference reference, {
    String language = 'en',
  }) => _post(
    reference.snapshotsPath,
    null,
    session: session,
    query: {'lang': language},
  );

  Future<Map<String, dynamic>> snapshotContent(
    ReportsViewerSession session,
    ReportsCardReference reference,
    String snapshotId,
  ) => api.request(
    '${reference.snapshotPath(snapshotId)}/content',
    headers: session.headers,
  );

  /// Public Reports catalog. The list is guest-readable; callers still need
  /// an owner session for mutations and private report content.
  Future<Map<String, dynamic>> projectCatalog({
    String language = 'en',
    int page = 1,
    int pageSize = 100,
  }) => api.request(
    '/catalog',
    query: {
      'lang': language,
      'page': '$page',
      'page_size': '${pageSize.clamp(1, 100)}',
    },
  );

  /// Public, published template discovery for a project.
  Future<Map<String, dynamic>> projectTemplates(
    String project, {
    String language = 'en',
    String? kind,
  }) => api.request(
    '/projects/${Uri.encodeComponent(project)}/templates',
    query: {'lang': language, 'kind': ?kind},
  );

  Future<Map<String, dynamic>> createOwnerItem({
    required String project,
    required String templateId,
    required int templateVersion,
    required Map<String, dynamic> mapping,
    required Map<String, dynamic> config,
    required List<Map<String, dynamic>> rows,
    required String title,
    required ReportsViewerSession session,
    required String idempotencyKey,
    String sourceApp = 'annotations',
  }) async {
    final payload = {'mapping': mapping, 'rows': rows};
    if (mapping.isEmpty ||
        mapping.entries.any(
          (entry) =>
              entry.key.trim().isEmpty ||
              entry.value is! String ||
              (entry.value as String).trim().isEmpty,
        )) {
      throw const ReportsUploadLimitException('invalid_mapping');
    }
    final encodedPayloadBytes = utf8.encode(jsonEncode(payload)).length;
    if (rows.length > 1000) {
      throw const ReportsUploadLimitException('payload_too_many_records');
    }
    if (encodedPayloadBytes > 1048576) {
      throw const ReportsUploadLimitException('payload_too_large');
    }
    return _post(
      '/me/projects/${Uri.encodeComponent(project)}/items',
      {
        'title': title,
        'source_app': sourceApp,
        'template_id': templateId,
        'template_version': templateVersion,
        'mapping': mapping,
        'config': config,
        'rows': rows,
        'idempotency_key': idempotencyKey,
      },
      session: session,
      idempotencyKey: idempotencyKey,
    );
  }
}

final class ReportsViewerSession {
  const ReportsViewerSession._({required this.userId, required this.headers});

  /// Trusted identity returned by Reports GET /me, used only for cache scoping.
  final String userId;
  final Map<String, String> headers;
}

final class ReportsSessionException implements Exception {
  const ReportsSessionException();
}

final class ReportsSessionChangedException implements Exception {
  const ReportsSessionChangedException();
}

final class ReportsUploadLimitException implements Exception {
  const ReportsUploadLimitException(this.code);
  final String code;
}
