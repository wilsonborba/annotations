import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:reports_view/reports_view.dart';

import '../../dal/local/reports_private_cache.dart';
import '../../dal/remote/api_adapter.dart';
import '../../dal/remote/reports_api_adapter.dart';
import '../models/reports_card_reference.dart';
import '../models/reports_embed_data.dart';
import '../models/note_document.dart';

final class ReportsSearchItem {
  const ReportsSearchItem({
    required this.project,
    required this.slug,
    required this.name,
    required this.chartTypes,
    required this.audience,
    required this.canView,
    required this.openInReportsUrl,
  });

  final String project;
  final String slug;
  final String name;
  final List<String> chartTypes;
  final String audience;
  final bool canView;
  final String openInReportsUrl;

  factory ReportsSearchItem.fromJson(Map<String, dynamic> json) =>
      ReportsSearchItem(
        project: _string(json['project']),
        slug: _string(json['slug']),
        name: _string(json['title']),
        chartTypes: (json['chart_types'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        audience: _string(json['audience']),
        canView: json['can_view'] == true,
        openInReportsUrl: _string(json['open_in_reports_url']),
      );
}

final class ReportsSearchPage {
  const ReportsSearchPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.language,
  });

  final List<ReportsSearchItem> items;
  final int page;
  final int pageSize;
  final int total;
  final String language;

  factory ReportsSearchPage.fromJson(Map<String, dynamic> json) =>
      ReportsSearchPage(
        items: (json['items'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) =>
                  ReportsSearchItem.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList(growable: false),
        page: _integer(json['page']),
        pageSize: _integer(json['page_size']),
        total: _integer(json['total']),
        language: _string(json['language']),
      );
}

/// An active project returned by Reports' public catalog. This intentionally
/// retains only fields the app needs to choose a real project.
final class ReportsProjectChoice {
  const ReportsProjectChoice({
    required this.slug,
    required this.name,
    required this.reportCount,
  });

  final String slug;
  final String name;
  final int reportCount;

  factory ReportsProjectChoice.fromJson(Map<String, dynamic> json) {
    final slug = json['slug'];
    final name = json['name'];
    final count = json['report_count'];
    if (slug is! String ||
        slug.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        count is! num ||
        count < 0 ||
        count % 1 != 0) {
      throw const FormatException('Invalid Reports project summary.');
    }
    return ReportsProjectChoice(
      slug: slug,
      name: name,
      reportCount: count.toInt(),
    );
  }
}

final class ReportsProjectPage {
  const ReportsProjectPage({
    required this.items,
    required this.page,
    required this.total,
  });
  final List<ReportsProjectChoice> items;
  final int page;
  final int total;

  factory ReportsProjectPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final page = json['page'];
    final total = json['total'];
    if (raw is! List ||
        raw.any((item) => item is! Map) ||
        page is! num ||
        total is! num ||
        page < 1 ||
        total < 0 ||
        page % 1 != 0 ||
        total % 1 != 0) {
      throw const FormatException('Invalid Reports catalog page.');
    }
    return ReportsProjectPage(
      items: raw
          .map(
            (item) => ReportsProjectChoice.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
      page: page.toInt(),
      total: total.toInt(),
    );
  }
}

/// Published template metadata is kept as JSON-shaped values so the UI uses
/// the exact slot and option names supplied by Reports rather than inventing
/// a local schema.
final class ReportsTemplateChoice {
  const ReportsTemplateChoice({
    required this.templateId,
    required this.version,
    required this.kind,
    required this.visual,
    required this.title,
    required this.slots,
    required this.options,
  });
  final String templateId;
  final int version;
  final String kind;
  final String visual;
  final String title;
  final List<Map<String, dynamic>> slots;
  final List<Map<String, dynamic>> options;

  factory ReportsTemplateChoice.fromJson(Map<String, dynamic> json) {
    final id = json['template_id'];
    final version = json['version'];
    final kind = json['kind'];
    final visual = json['visual'];
    final title = json['title'];
    if (id is! String ||
        id.trim().isEmpty ||
        version is! num ||
        kind is! String ||
        visual is! String ||
        title is! String) {
      throw const FormatException('Invalid Reports template metadata.');
    }
    List<Map<String, dynamic>> objects(String key) {
      final value = json[key];
      if (value is! List || value.any((entry) => entry is! Map)) {
        throw FormatException('Invalid Reports template $key.');
      }
      return value
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(growable: false);
    }

    return ReportsTemplateChoice(
      templateId: id,
      version: version.toInt(),
      kind: kind,
      visual: visual,
      title: title,
      slots: objects('slots'),
      options: objects('options'),
    );
  }
}

/// Adapter/service seam used by Annotations editing, reading, and export.
/// It returns authorized Reports schemas and rows for reports_view, or a
/// content-free access state. It never writes Reports data into a note.
final class ReportsEmbedSource {
  ReportsEmbedSource({
    required this.api,
    ReportsPrivateCache? cache,
    this.hasStoredViewerSession,
  }) : cache = cache ?? PreferencesReportsPrivateCache();

  final ReportsApiAdapter api;
  final ReportsPrivateCache cache;

  /// True only when the app's existing secure session state says this device
  /// remains signed in. It gates offline cache reads; it does not authorize API
  /// requests, which Reports verifies through the gateway on every call.
  final Future<bool> Function()? hasStoredViewerSession;

  String? _activeUserId;

  Future<ReportsProjectPage> projectCatalog({
    String language = 'en',
    int page = 1,
  }) async {
    final session = await _viewerSession();
    final result = ReportsProjectPage.fromJson(
      await api.projectCatalog(language: language, page: page),
    );
    await _assertSameViewer(session);
    return result;
  }

  Future<List<ReportsProjectChoice>> allProjects({
    String language = 'en',
  }) async {
    final projects = <ReportsProjectChoice>[];
    var pageNumber = 1;
    var total = 0;
    do {
      final page = await projectCatalog(language: language, page: pageNumber);
      if (page.page != pageNumber) {
        throw const FormatException(
          'Reports catalog page changed unexpectedly.',
        );
      }
      projects.addAll(page.items);
      total = page.total;
      if (page.items.isEmpty && projects.length < total) {
        throw const FormatException('Reports catalog ended before its total.');
      }
      if (projects.length >= total) break;
      pageNumber++;
    } while (true);
    return List.unmodifiable(projects);
  }

  Future<List<ReportsTemplateChoice>> templatesForProject(
    String project, {
    String language = 'en',
  }) async {
    final session = await _viewerSession();
    final response = await api.projectTemplates(project, language: language);
    await _assertSameViewer(session);
    final templates = response['templates'];
    if (templates is! List || templates.any((entry) => entry is! Map)) {
      throw const FormatException('Invalid Reports templates response.');
    }
    return templates
        .map(
          (entry) => ReportsTemplateChoice.fromJson(
            Map<String, dynamic>.from(entry as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<ReportsEmbedData> loadEmbed(
    ReportsEmbed item, {
    required String trustedAccountId,
    String language = 'en',
  }) => loadDocument(
    item.toJson(),
    trustedAccountId: trustedAccountId,
    language: language,
  );

  Future<ReportsSearchPage> searchReports({
    required String project,
    required String query,
    String? tier,
    String language = 'en',
    int page = 1,
    int pageSize = 12,
  }) async {
    final session = await _viewerSession();
    final result = await api.searchReports(
      session,
      project: project,
      query: query,
      tier: tier,
      language: language,
      page: page,
      pageSize: pageSize,
    );
    await _assertSameViewer(session);
    return ReportsSearchPage.fromJson(result);
  }

  Future<ReportView> reportViewForSearchItem(
    ReportsSearchItem item, {
    String language = 'en',
  }) async {
    final session = await _viewerSession();
    final report = await api.reportViewFor(
      session,
      project: item.project,
      report: item.slug,
      language: language,
    );
    await _assertSameViewer(session);
    if (report.project != item.project || report.report != item.slug) {
      throw const ReportsChangingDatasetException();
    }
    return report;
  }

  Future<ReportsEmbedData> loadDocument(
    Map<String, dynamic> item, {
    String? trustedAccountId,
    String language = 'en',
    bool publicProjection = false,
  }) async {
    final rawReference = item['report_id'];
    ReportsCardReference? reference;

    // Public projections contain only generic restricted output. Never infer
    // an address from a legacy id or request source data on their behalf.
    if (publicProjection || item['restricted'] == true) {
      return _state(ReportsEmbedState.restricted, null);
    }
    if (item['kind'] != 'reports_embed') {
      return _state(ReportsEmbedState.unavailable, null);
    }

    final mode = item['mode'];
    if (mode != 'live' && mode != 'snapshot') {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    final snapshotId = item['snapshot_id'];
    final source = item['source'];
    if (source != 'link' && source != 'upload') {
      return _state(ReportsEmbedState.unavailable, null);
    }
    final projectSlug = item['project_slug'];
    final reportSlug = item['report_slug'];
    final datasetId = item['dataset_id'];
    if (projectSlug is! String ||
        reportSlug is! String ||
        datasetId is! String) {
      return _state(ReportsEmbedState.unavailable, null);
    }
    reference = ReportsCardReference.fromFields(
      project: projectSlug,
      report: reportSlug,
      dataset: datasetId,
    );
    if (reference == null || rawReference is! String) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    if ((source == 'link' && rawReference != reportSlug) ||
        (source == 'upload' && !_validOwnerItemId(rawReference))) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    if (mode == 'snapshot' &&
        (snapshotId is! String || snapshotId.trim().isEmpty)) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    if (trustedAccountId == null || trustedAccountId.trim().isEmpty) {
      return _state(ReportsEmbedState.signInRequired, reference);
    }

    final logicalKey = _logicalCacheKey(
      reference,
      mode as String,
      mode == 'snapshot' ? snapshotId as String : '',
      language,
    );
    try {
      final session = await _viewerSession(expectedAccountId: trustedAccountId);
      final raw = mode == 'snapshot'
          ? await api.snapshotContent(session, reference, snapshotId as String)
          : await _liveData(session, reference, language);
      if (mode == 'snapshot' &&
          (raw['id'] != snapshotId ||
              raw['project'] != reference.project ||
              raw['report'] != reference.report ||
              raw['dataset_id'] != reference.dataset)) {
        throw const ReportsChangingDatasetException();
      }
      await _assertSameViewer(session);
      final cachedAt = DateTime.now().toUtc();
      try {
        await cache.write(session.userId, logicalKey, {
          'cached_at': cachedAt.toIso8601String(),
          'mode': mode,
          'snapshot_id': mode == 'snapshot' ? snapshotId : null,
          'payload': raw,
        });
      } catch (_) {
        // A local cache failure does not invalidate the authorized response.
      }
      return _toEmbedData(
        reference,
        mode,
        raw,
        ReportsEmbedState.readable,
        cachedAt: cachedAt,
      );
    } on ApiError catch (error) {
      if (error.status == 401) {
        await clearRestrictedCache();
        return _state(ReportsEmbedState.signInRequired, reference);
      }
      if (error.status == 403 || error.status == 404) {
        final userId = _activeUserId;
        if (userId != null) {
          await cache.remove(userId, logicalKey);
        }
        return _state(
          error.status == 403
              ? ReportsEmbedState.restricted
              : ReportsEmbedState.unavailable,
          reference,
        );
      }
      if (error.status >= 500) {
        return _offlineOrUnavailable(
          reference,
          mode,
          logicalKey,
          trustedAccountId: trustedAccountId,
        );
      }
      return _state(ReportsEmbedState.unavailable, reference);
    } on ReportsSessionException {
      await clearRestrictedCache();
      return _state(ReportsEmbedState.signInRequired, reference);
    } on ReportsSessionChangedException {
      await clearRestrictedCache();
      return _state(ReportsEmbedState.signInRequired, reference);
    } on ReportsAccessException {
      final userId = _activeUserId;
      if (userId != null) {
        await cache.remove(userId, logicalKey);
      }
      return _state(ReportsEmbedState.restricted, reference);
    } on ReportsChangingDatasetException {
      final userId = _activeUserId;
      if (userId != null) {
        await cache.remove(userId, logicalKey);
      }
      return _state(ReportsEmbedState.unavailable, reference);
    } on http.ClientException {
      return _offlineOrUnavailable(
        reference,
        mode,
        logicalKey,
        trustedAccountId: trustedAccountId,
      );
    } catch (_) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
  }

  Future<Map<String, dynamic>> _liveData(
    ReportsViewerSession session,
    ReportsCardReference reference,
    String language,
  ) async {
    final reportJson = await api.reportViewJson(
      session,
      reference,
      language: language,
    );
    final report = ReportView.fromJson(reportJson);
    if (report.project != reference.project ||
        report.report != reference.report) {
      throw const ReportsChangingDatasetException();
    }
    final descriptor = report.datasets
        .where((entry) => entry.datasetId == reference.dataset)
        .firstOrNull;
    if (descriptor == null || !descriptor.canView) {
      throw const ReportsAccessException();
    }

    final pageJson = await api.datasetPageJson(
      session,
      reference,
      language: language,
      offset: 0,
      limit: 5000,
    );
    final page = DatasetPage.fromJson(pageJson);
    if (!page.descriptor.canView) throw const ReportsAccessException();
    if (page.descriptor.datasetId != reference.dataset) {
      throw const ReportsChangingDatasetException();
    }

    return {'report_view': reportJson, 'dataset_page': pageJson};
  }

  Future<ReportsEmbedData> _offlineOrUnavailable(
    ReportsCardReference? reference,
    Object mode,
    String logicalKey, {
    required String? trustedAccountId,
  }) async {
    if (reference == null) return _state(ReportsEmbedState.unavailable, null);
    bool signedIn;
    try {
      signedIn = await hasStoredViewerSession?.call() ?? false;
    } catch (_) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    if (!signedIn) return _state(ReportsEmbedState.unavailable, reference);
    final userId = trustedAccountId;
    Map<String, dynamic>? entry;
    try {
      entry = userId == null ? null : await cache.read(userId, logicalKey);
    } catch (_) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    if (entry == null || entry['payload'] is! Map) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    final cachedAt = DateTime.tryParse('${entry['cached_at'] ?? ''}')?.toUtc();
    return _toEmbedData(
      reference,
      mode,
      Map<String, dynamic>.from(entry['payload'] as Map),
      ReportsEmbedState.offline,
      cachedAt: cachedAt,
    );
  }

  Future<ReportsViewerSession> _viewerSession({
    String? expectedAccountId,
  }) async {
    final session = await api.viewerSession();
    if (expectedAccountId != null && session.userId != expectedAccountId) {
      await clearRestrictedCache();
      throw const ReportsSessionChangedException();
    }
    if (_activeUserId != null && _activeUserId != session.userId) {
      await cache.clear();
    }
    _activeUserId = session.userId;
    await _bindAccount(session.userId);
    return session;
  }

  Future<void> _assertSameViewer(ReportsViewerSession session) async {
    final current = await api.viewerSession();
    if (current.userId != session.userId) {
      await clearRestrictedCache();
      throw const ReportsSessionChangedException();
    }
  }

  Future<void> _bindAccount(String accountId) async {
    if (cache is PreferencesReportsPrivateCache) {
      await (cache as PreferencesReportsPrivateCache).bindAccount(accountId);
    }
  }

  Future<void> clearRestrictedCache() async {
    await cache.clear();
    _activeUserId = null;
  }

  Future<ReportsEmbedReference> captureSnapshot({
    required ReportsCardReference reference,
    required String reportId,
    required String source,
    String language = 'en',
  }) async {
    if (source != 'link' && source != 'upload') {
      throw ArgumentError.value(source, 'source');
    }
    if ((source == 'link' && reportId != reference.report) ||
        (source == 'upload' && !_validOwnerItemId(reportId))) {
      throw const FormatException(
        'The Notes Reports reference must use a backend-valid identifier.',
      );
    }
    final session = await _viewerSession();
    final meta = await api.captureSnapshot(
      session,
      reference,
      language: language,
    );
    await _assertSameViewer(session);
    final id = meta['id'];
    final capturedAtText = meta['captured_at'];
    if (id is! String ||
        !_validOwnerItemId(id) ||
        capturedAtText is! String ||
        meta['project'] != reference.project ||
        meta['report'] != reference.report ||
        meta['dataset_id'] != reference.dataset) {
      throw const FormatException(
        'Reports returned invalid snapshot metadata.',
      );
    }
    final capturedAt = DateTime.tryParse(capturedAtText);
    if (capturedAt == null) {
      throw const FormatException('Reports returned invalid snapshot time.');
    }
    return ReportsEmbedReference(
      reportId: reportId,
      projectSlug: reference.project,
      reportSlug: reference.report,
      datasetId: reference.dataset,
      mode: 'snapshot',
      source: source,
      snapshotId: id,
      capturedAt: capturedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<ReportsEmbedReference> uploadRows({
    required String project,
    required String title,
    required String templateId,
    required int templateVersion,
    required Map<String, dynamic> mapping,
    required Map<String, dynamic> config,
    required List<Map<String, dynamic>> rows,
    required String idempotencyKey,
  }) async {
    final session = await _viewerSession();
    final result = await api.createOwnerItem(
      session: session,
      project: project,
      title: title,
      templateId: templateId,
      templateVersion: templateVersion,
      mapping: mapping,
      config: config,
      rows: rows,
      idempotencyKey: idempotencyKey,
    );
    await _assertSameViewer(session);
    final item = result['item'];
    if (item is! Map || item['id'] is! String) {
      throw const FormatException('Reports returned an invalid owner item.');
    }
    final itemProject = item['project'];
    final itemReport = item['report_slug'];
    final itemDataset = item['dataset_id'];
    final itemEmbedUrl = item['embed_url'];
    if (!_validOwnerItemId(item['id'] as String) ||
        itemProject is! String ||
        itemReport is! String ||
        itemDataset is! String ||
        itemEmbedUrl is! String ||
        itemProject != project) {
      throw const FormatException(
        'Reports returned invalid owner item identity.',
      );
    }
    final reference = ReportsCardReference.fromFields(
      project: itemProject,
      report: itemReport,
      dataset: itemDataset,
    );
    if (reference == null) {
      throw const FormatException('Reports returned an invalid card identity.');
    }
    if (ReportsCardReference.tryParse(itemEmbedUrl) != reference) {
      throw const FormatException(
        'Reports returned mismatched owner item identity.',
      );
    }
    return ReportsEmbedReference(
      reportId: item['id'] as String,
      projectSlug: reference.project,
      reportSlug: reference.report,
      datasetId: reference.dataset,
      mode: 'live',
      source: 'upload',
    );
  }

  bool _validOwnerItemId(String id) =>
      ReportsCardReference.isValidOwnerItemId(id);

  ReportsEmbedData _toEmbedData(
    ReportsCardReference reference,
    Object mode,
    Map<String, dynamic> raw,
    ReportsEmbedState state, {
    DateTime? cachedAt,
  }) {
    if (mode == 'snapshot') {
      final rawDescriptor = raw['descriptor'];
      final rawRows = raw['rows'];
      if (rawDescriptor is! Map || rawRows is! List) {
        return _state(ReportsEmbedState.unavailable, reference);
      }
      final descriptorJson = Map<String, dynamic>.from(rawDescriptor);
      final page = DatasetPage.fromJson({
        ...descriptorJson,
        'rows': rawRows,
        'offset': 0,
        'limit': rawRows.length,
        'total_rows': _integer(raw['total_rows']),
      });
      if (page.descriptor.datasetId != reference.dataset ||
          !page.descriptor.canView) {
        return _state(ReportsEmbedState.unavailable, reference);
      }
      final capturedAt = DateTime.tryParse(
        '${raw['captured_at'] ?? ''}',
      )?.toUtc();
      return ReportsEmbedData(
        state: state,
        reference: reference,
        descriptor: page.descriptor,
        page: page,
        capturedAt: capturedAt,
        cachedAt: cachedAt,
        openInReportsUrl: _string(raw['open_in_reports_url']),
        complete: rawRows.length >= _integer(raw['total_rows']),
      );
    }

    final rawView = raw['report_view'];
    final rawPage = raw['dataset_page'];
    if (rawView is! Map || rawPage is! Map) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    final view = ReportView.fromJson(Map<String, dynamic>.from(rawView));
    final page = DatasetPage.fromJson(Map<String, dynamic>.from(rawPage));
    if (view.project != reference.project ||
        view.report != reference.report ||
        view.dataset(reference.dataset) == null ||
        page.descriptor.datasetId != reference.dataset ||
        !page.descriptor.canView) {
      return _state(ReportsEmbedState.unavailable, reference);
    }
    return ReportsEmbedData(
      state: state,
      reference: reference,
      reportView: view,
      descriptor: page.descriptor,
      page: page,
      cachedAt: cachedAt,
      openInReportsUrl: reference.sourceUrl,
      complete: page.rows.length >= page.totalRows,
    );
  }

  ReportsEmbedData _state(
    ReportsEmbedState state,
    ReportsCardReference? reference,
  ) => ReportsEmbedData(state: state, reference: reference);

  String _logicalCacheKey(
    ReportsCardReference reference,
    String mode,
    String snapshotId,
    String language,
  ) => sha256
      .convert(
        utf8.encode(
          '${reference.sourceUrl}\u001f$mode\u001f$snapshotId\u001f$language',
        ),
      )
      .toString();
}

final class ReportsAccessException implements Exception {
  const ReportsAccessException();
}

final class ReportsChangingDatasetException implements Exception {
  const ReportsChangingDatasetException();
}

String _string(Object? value) => value is String ? value : '';
int _integer(Object? value) => value is num ? value.toInt() : 0;
