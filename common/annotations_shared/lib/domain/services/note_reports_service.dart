import '../../dal/remote/api_adapter.dart';
import '../models/reports_card_reference.dart';
import '../models/reports_embed_data.dart';
import 'native_auth_service.dart';

/// Creates one Reports item through the saved note's owner-scoped receipt.
/// The Notes API is the authority for provenance and idempotency; this client
/// never creates the Reports item directly.
final class NoteReportsService {
  const NoteReportsService({required this.api, required this.session});

  final ApiAdapter api;
  final NativeSession session;

  Future<ReportsEmbedReference> createChart({
    required String serverNoteId,
    required String project,
    required String operationKey,
    required Map<String, Object?> item,
  }) async {
    final noteId = serverNoteId.trim();
    final key = operationKey.trim();
    if (noteId.isEmpty ||
        project.trim().isEmpty ||
        key.isEmpty ||
        key.length > 128) {
      throw const FormatException('Invalid Reports creation request.');
    }

    final response = await api.request(
      '/me/notes/${Uri.encodeComponent(noteId)}/reports',
      method: 'POST',
      headers: session.authHeaders(isMutation: true),
      body: {
        'mode': 'create',
        'project': project,
        'operation_key': key,
        'item': item,
      },
    );

    final returnedNoteId = response['note_id'];
    final itemId = response['report_item_id'];
    final relationKind = response['relation_kind'];
    final returnedOperationKey = response['operation_key'];
    final rawItem = response['item'];
    if (returnedNoteId != noteId ||
        itemId is! String ||
        !ReportsCardReference.isValidOwnerItemId(itemId) ||
        relationKind != 'created_for_note' ||
        returnedOperationKey != key ||
        rawItem is! Map) {
      throw const FormatException(
        'Notes API returned an invalid report receipt.',
      );
    }

    final metadata = Map<String, dynamic>.from(rawItem);
    final metadataId = metadata['id'];
    final metadataProject = metadata['project'];
    final reportSlug = metadata['report_slug'];
    final datasetId = metadata['dataset_id'];
    final sourceApp = metadata['source_app'];
    final templateId = metadata['template_id'];
    final templateVersion = metadata['template_version'];
    final audience = metadata['audience'];
    final authority = metadata['control_authority'];
    final etag = metadata['etag'];
    final embedUrl = metadata['embed_url'];
    if (metadataId != itemId ||
        metadataProject != project ||
        reportSlug is! String ||
        datasetId is! String ||
        sourceApp != 'annotations' ||
        templateId != item['template_id'] ||
        templateVersion != item['template_version'] ||
        audience != 'personal' ||
        authority != 'user_owned' ||
        etag is! String ||
        etag.isEmpty ||
        embedUrl is! String) {
      throw const FormatException(
        'Notes API returned invalid report metadata.',
      );
    }
    final reference = ReportsCardReference.fromFields(
      project: metadataProject as String,
      report: reportSlug,
      dataset: datasetId,
    );
    if (reference == null ||
        ReportsCardReference.tryParse(embedUrl) != reference) {
      throw const FormatException('Notes API returned an invalid embed URL.');
    }

    return ReportsEmbedReference(
      reportId: itemId,
      projectSlug: reference.project,
      reportSlug: reference.report,
      datasetId: reference.dataset,
      mode: 'live',
      source: 'upload',
    );
  }
}
