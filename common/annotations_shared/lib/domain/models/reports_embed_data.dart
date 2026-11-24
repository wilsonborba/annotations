import 'package:reports_view/reports_view.dart';

import 'reports_card_reference.dart';

enum ReportsEmbedState {
  readable,
  offline,
  signInRequired,
  restricted,
  unavailable,
}

/// A Reports card loaded with viewer permissions and converted to the shared
/// renderer contract. A missing [page] means there are no authorized rows.
final class ReportsEmbedData {
  const ReportsEmbedData({
    required this.state,
    required this.reference,
    this.reportView,
    this.descriptor,
    this.page,
    this.capturedAt,
    this.cachedAt,
    this.openInReportsUrl,
    this.complete = true,
  });

  final ReportsEmbedState state;
  final ReportsCardReference? reference;
  final ReportView? reportView;
  final DatasetDescriptor? descriptor;
  final DatasetPage? page;
  final DateTime? capturedAt;
  final DateTime? cachedAt;
  final String? openInReportsUrl;
  final bool complete;

  bool get canRender =>
      (state == ReportsEmbedState.readable ||
          state == ReportsEmbedState.offline) &&
      descriptor != null &&
      page != null;
}

/// The minimal note data written after an upload or explicit snapshot capture.
/// These keys are already part of the Annotations document schema.
final class ReportsEmbedReference {
  const ReportsEmbedReference({
    required this.reportId,
    required this.projectSlug,
    required this.reportSlug,
    required this.datasetId,
    required this.mode,
    required this.source,
    this.snapshotId,
    this.capturedAt,
  });

  final String reportId;
  final String projectSlug;
  final String reportSlug;
  final String datasetId;
  final String mode;
  final String source;
  final String? snapshotId;

  /// Unix seconds, matching the Annotations document schema.
  final int? capturedAt;

  Map<String, Object?> toDocumentFields() => {
    'report_id': reportId,
    'project_slug': projectSlug,
    'report_slug': reportSlug,
    'dataset_id': datasetId,
    'mode': mode,
    'source': source,
    if (mode == 'snapshot') 'snapshot_id': snapshotId,
    if (mode == 'snapshot') 'captured_at': capturedAt,
  };
}
