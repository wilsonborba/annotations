import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../../../dal/remote/transcription_api_adapter.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/models/transcription_session.dart';
import '../../../../domain/services/local_note_store.dart';
import '../../../../domain/services/editor_rules.dart';
import '../../../../domain/services/model_download_service.dart';
import '../../../../domain/services/transcription_draft_service.dart';
import '../../../../domain/services/transcription_run_service.dart';
import '../../../../domain/services/transcription_workflow_service.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';

/// Dependencies supplied only by the fixture-enabled editor entry point while
/// the released feature switch remains off. A real runtime is supplied by a
/// reviewed model release; this page never constructs or activates one.
final class TranscriptionReviewAccess {
  const TranscriptionReviewAccess({
    required this.workflow,
    required this.runtime,
    required this.platform,
  });

  final TranscriptionWorkflowService workflow;
  final TranscriptionRuntime runtime;
  final String platform;
}

/// Explicitly converts selected Original units into a saved review draft.
/// The page uses the current owner session and existing download/run services.
class TranscriptionReviewPage extends StatefulWidget {
  const TranscriptionReviewPage({
    super.key,
    required this.note,
    required this.access,
    required this.store,
    required this.ownerAccountId,
    required this.isOwnerScopeCurrent,
    this.initialSelectedItemIds = const [],
  });

  final LocalNote note;
  final TranscriptionReviewAccess access;
  final LocalNoteStore store;
  final String ownerAccountId;
  final bool Function() isOwnerScopeCurrent;
  final List<String> initialSelectedItemIds;

  @override
  State<TranscriptionReviewPage> createState() =>
      _TranscriptionReviewPageState();
}

class _TranscriptionReviewPageState extends State<TranscriptionReviewPage> {
  late final List<String> _units;
  late final Map<String, Map<String, Object?>> _itemsById;
  late final String _documentHash;
  late final String? _sourceRevisionId;
  final Set<String> _selected = {};
  final Map<String, TextEditingController> _controllers = {};
  ModelListing? _listing;
  String? _modelVersion;
  TranscriptionDraft? _draft;
  String? _stage;
  String? _error;
  bool _busy = false;
  bool _checkingSavedDraft = true;
  bool _sourceChanged = false;
  bool _invalidInitialSelection = false;

  TranscriptionWorkflowService get _workflow => widget.access.workflow;

  @override
  void initState() {
    super.initState();
    final document = widget.note.document;
    if (document is! PaperDocument ||
        document.schema.family != DocumentFamily.original) {
      throw ArgumentError('Transcription requires an Original paper note.');
    }
    final layout = DocumentLayout.of(document)!;
    _units = layout.units;
    _itemsById = {for (final item in document.itemsJson) '${item['id']}': item};
    final selectedInEditor = widget.initialSelectedItemIds.toSet();
    if (selectedInEditor.isEmpty) {
      _selected.addAll(_units);
    } else if (selectedInEditor.every(_units.contains)) {
      _selected.addAll(selectedInEditor);
    } else {
      // A stale, nonempty editor selection is not permission to widen the
      // conversion to every source unit. Require a fresh explicit choice.
      _invalidInitialSelection = true;
    }
    _documentHash = sha256
        .convert(utf8.encode(jsonEncode(document.toJson())))
        .toString();
    _sourceRevisionId = widget.note.syncState == LocalSyncState.synced
        ? widget.note.serverOriginalRevisionId
        : null;
    for (final unit in _units) {
      _controllers[unit] = TextEditingController();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeSavedDraft());
  }

  Future<void> _resumeSavedDraft() async {
    if (!widget.isOwnerScopeCurrent()) return;
    final existing = _workflow.drafts.reopenDraft(
      widget.note.id,
      accountId: widget.ownerAccountId,
    );
    if (existing == null) {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() => _checkingSavedDraft = false);
      }
      return;
    }
    final sourceHash = _sourceRevisionId == null ? _documentHash : null;
    final changed =
        existing.sourceRevision != widget.note.revision ||
        existing.baseSourceRevisionId != _sourceRevisionId ||
        existing.baseSourceHash != sourceHash;
    if (changed) {
      _workflow.drafts.markSourceChanged(
        widget.note.id,
        newSourceRevision: widget.note.revision,
        newSourceRevisionId: _sourceRevisionId,
        newSourceHash: sourceHash,
        accountId: widget.ownerAccountId,
      );
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _draft = _workflow.drafts.reopenDraft(
            widget.note.id,
            accountId: widget.ownerAccountId,
          );
          _sourceChanged = true;
          _checkingSavedDraft = false;
          _syncControllers();
        });
      }
      return;
    }
    setState(() {
      _busy = true;
      _stage = context.tr('transcriptionResuming');
      _error = null;
    });
    try {
      final recovered = await _workflow.resumeLocal(
        noteId: widget.note.id,
        runtime: widget.access.runtime,
        onStage: _setStage,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _draft = recovered;
        _busy = false;
        _checkingSavedDraft = false;
        _stage = null;
        _syncControllers();
      });
    } on Object {
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _busy = false;
        _checkingSavedDraft = false;
        _stage = null;
        _error = context.tr('transcriptionResumeFailed');
      });
    }
  }

  void _setStage(String stage) {
    if (!mounted || !widget.isOwnerScopeCurrent()) return;
    setState(() => _stage = stage);
  }

  String get _language {
    final locale = AppScope.of(context).preferences.locale;
    return switch (locale) {
      'pt' || 'pt_BR' || 'pt-BR' => 'pt-BR',
      'th' => 'th',
      _ => 'en',
    };
  }

  Future<void> _loadModels() async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _workflow.downloads.sessionProvider();
      if (session == null) throw const TranscriptionSignInRequiredException();
      session.requireCurrent();
      final listing = await _workflow.downloads.api.listModels(
        session,
        platform: widget.access.platform,
        language: _language,
      );
      session.requireCurrent();
      if (!widget.isOwnerScopeCurrent()) return;
      final available = listing.models.where(
        (model) =>
            model.status == 'published' &&
            model.artifactFor(widget.access.platform) != null &&
            model.languages.contains(_language),
      );
      if (available.isEmpty) throw const ModelArtifactUnavailableException();
      setState(() {
        _listing = ModelListing(
          defaultVersion: listing.defaultVersion,
          models: available.toList(growable: false),
        );
        _modelVersion =
            listing.defaultVersion != null &&
                available.any((m) => m.version == listing.defaultVersion)
            ? listing.defaultVersion
            : available.first.version;
      });
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() => _error = context.tr('transcriptionModelsFailed'));
      }
    } finally {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _convert() async {
    if (_checkingSavedDraft ||
        _busy ||
        _selected.isEmpty ||
        !widget.isOwnerScopeCurrent()) {
      return;
    }
    final version = _modelVersion;
    if (version == null) {
      await _loadModels();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _stage = context.tr('transcriptionDownloading');
    });
    try {
      final selectedIds = [
        for (final id in _units)
          if (_selected.contains(id)) id,
      ];
      final document = widget.note.document as PaperDocument;
      final layout = DocumentLayout.of(document)!;
      final include = <String>{};
      for (final id in selectedIds) {
        include.addAll(layout.withDescendants(id));
      }
      final sourceItems = [for (final id in selectedIds) _itemsById[id]!];
      final selectedDocument = <String, Object?>{
        ...document.toJson(),
        'items': [
          for (final item in document.itemsJson)
            if (include.contains('${item['id']}')) item,
        ],
      };
      final downloaded = await _workflow.downloads.download(
        version: version,
        platform: widget.access.platform,
      );
      if (!widget.isOwnerScopeCurrent()) return;
      final draft = await _workflow.startLocal(
        noteId: widget.note.id,
        localSourceRevision: widget.note.revision,
        sourceRevisionId: _sourceRevisionId,
        sourceHash: _sourceRevisionId == null ? _documentHash : null,
        selectedSourceItems: sourceItems,
        selectedSourceItemIds: selectedIds,
        selectedInkDocument: selectedDocument,
        downloaded: downloaded,
        language: _language,
        schemaVersion: widget.note.schema.version,
        runtime: widget.access.runtime,
        onStage: _setStage,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _draft = draft;
        _stage = null;
        _busy = false;
        _syncControllers();
      });
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _stage = null;
          _error = context.tr('transcriptionConvertFailed');
        });
      }
    }
  }

  Future<bool> _correct(TranscriptionPassage passage) async {
    if (_busy || !widget.isOwnerScopeCurrent()) return false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _workflow.correctPassage(
        noteId: widget.note.id,
        partId: passage.partId,
        correctedText: _controllers[passage.partId]?.text ?? passage.text,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return false;
      setState(() {
        _draft = _workflow.drafts.reopenDraft(
          widget.note.id,
          accountId: widget.ownerAccountId,
        );
        _busy = false;
        _syncControllers();
      });
      return true;
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = context.tr('transcriptionFeedbackFailed');
        });
      }
      return false;
    }
  }

  Future<void> _acceptText(TranscriptionPassage passage) async {
    if (!await _correct(passage)) return;
    if (!mounted || !widget.isOwnerScopeCurrent()) return;
    final current = _workflow.drafts.reopenDraft(
      widget.note.id,
      accountId: widget.ownerAccountId,
    );
    final corrected = current?.passages.where(
      (p) => p.partId == passage.partId,
    );
    if (corrected == null || corrected.length != 1) return;
    await _acceptCorrection(corrected.single);
  }

  Future<void> _acceptCorrection(TranscriptionPassage passage) async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() => _busy = true);
    try {
      await _workflow.acceptCorrection(
        noteId: widget.note.id,
        partId: passage.partId,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _draft = _workflow.drafts.reopenDraft(
          widget.note.id,
          accountId: widget.ownerAccountId,
        );
        _busy = false;
      });
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = context.tr('transcriptionFeedbackFailed');
        });
      }
    }
  }

  Future<void> _keepInk(TranscriptionPassage passage) async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() => _busy = true);
    try {
      await _workflow.keepPassageAsInk(
        noteId: widget.note.id,
        partId: passage.partId,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _draft = _workflow.drafts.reopenDraft(
          widget.note.id,
          accountId: widget.ownerAccountId,
        );
        _busy = false;
      });
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = context.tr('transcriptionFeedbackFailed');
        });
      }
    }
  }

  void _move(int index, int delta) {
    final draft = _draft;
    final target = index + delta;
    if (draft == null ||
        _busy ||
        target < 0 ||
        target >= draft.passages.length ||
        !widget.isOwnerScopeCurrent()) {
      return;
    }
    setState(() {
      _draft = _workflow.drafts.reorderPassage(
        widget.note.id,
        index,
        target,
        accountId: widget.ownerAccountId,
      );
      _syncControllers();
    });
  }

  Future<void> _acceptTyped() async {
    final draft = _draft;
    if (draft == null ||
        _busy ||
        _sourceChanged ||
        draft.needsReview ||
        draft.passages.isEmpty ||
        draft.passages.any((p) => !p.feedbackAccepted) ||
        !widget.isOwnerScopeCurrent()) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _workflow.drafts.acceptToTypedNote(
        widget.note.id,
        store: widget.store,
        accountId: widget.ownerAccountId,
      );
      if (mounted && widget.isOwnerScopeCurrent()) {
        Navigator.of(context).pop(true);
      }
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = context.tr('transcriptionAcceptFailed');
        });
      }
    }
  }

  Future<void> _retryFeedback() async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _workflow.retryPendingFeedback();
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _draft = _workflow.drafts.reopenDraft(
          widget.note.id,
          accountId: widget.ownerAccountId,
        );
        _busy = false;
      });
    } on Object {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = context.tr('transcriptionFeedbackFailed');
        });
      }
    }
  }

  void _syncControllers() {
    final draft = _draft;
    if (draft == null) return;
    for (final passage in draft.passages) {
      final controller = _controllers.putIfAbsent(
        passage.partId,
        TextEditingController.new,
      );
      if (controller.text != passage.text) controller.text = passage.text;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (!widget.isOwnerScopeCurrent()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(false);
        }
      });
      return Scaffold(
        body: Center(child: Text(context.tr('transcriptionSessionChanged'))),
      );
    }
    final draft = _draft;
    final models = _listing?.models ?? const <ModelReleaseManifest>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('transcriptionTitle')),
        leading: IconButton(
          key: const Key('transcription-cancel'),
          tooltip: context.tr('transcriptionCancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      key: const Key('transcription-error'),
                      style: TextStyle(color: colors.danger),
                    ),
                  ),
                if (_stage != null)
                  ListTile(
                    key: const Key('transcription-progress'),
                    leading: const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text(_stage!),
                  ),
                if (_sourceChanged || (draft?.needsReview ?? false))
                  Card(
                    key: const Key('transcription-source-changed'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(context.tr('transcriptionSourceChanged')),
                    ),
                  ),
                if (_invalidInitialSelection)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr('transcriptionSelectionInvalid'),
                      key: const Key('transcription-selection-invalid'),
                    ),
                  ),
                if (draft == null) ...[
                  if (_checkingSavedDraft)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    Text(context.tr('transcriptionChooseSource')),
                    for (final id in _units)
                      CheckboxListTile(
                        key: Key('transcription-source-$id'),
                        value: _selected.contains(id),
                        title: Text(_sourceLabel(id)),
                        onChanged: _busy
                            ? null
                            : (selected) => setState(() {
                                _invalidInitialSelection = false;
                                if (selected == true) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                      ),
                    if (models.isNotEmpty)
                      DropdownButtonFormField<String>(
                        key: const Key('transcription-model'),
                        initialValue: _modelVersion,
                        decoration: InputDecoration(
                          labelText: context.tr('transcriptionModel'),
                        ),
                        items: [
                          for (final model in models)
                            DropdownMenuItem(
                              value: model.version,
                              child: Text(model.version),
                            ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _modelVersion = value),
                      ),
                    Row(
                      children: [
                        if (_listing == null)
                          Expanded(
                            child: AppButton(
                              key: const Key('transcription-load-models'),
                              label: context.tr('transcriptionChooseModel'),
                              onPressed: _busy ? null : _loadModels,
                            ),
                          ),
                        if (_listing != null) ...[
                          Expanded(
                            child: AppButton.primary(
                              key: const Key('transcription-convert'),
                              label: context.tr('transcriptionConvert'),
                              onPressed: _busy || _selected.isEmpty
                                  ? null
                                  : _convert,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
                if (draft != null) ...[
                  Text(
                    context.tr('transcriptionReviewSaved'),
                    key: const Key('transcription-draft-saved'),
                  ),
                  for (var i = 0; i < draft.passages.length; i++)
                    _passageCard(context, draft, i),
                  if (draft.pendingFeedbackEvents.isNotEmpty)
                    AppButton(
                      key: const Key('transcription-retry-feedback'),
                      label: context.tr('transcriptionRetryFeedback'),
                      onPressed: _busy ? null : _retryFeedback,
                    ),
                  const SizedBox(height: 12),
                  AppButton.primary(
                    key: const Key('transcription-accept-typed'),
                    label: context.tr('transcriptionAcceptTyped'),
                    onPressed:
                        _busy ||
                            _sourceChanged ||
                            draft.needsReview ||
                            draft.passages.isEmpty ||
                            draft.passages.any((p) => !p.feedbackAccepted)
                        ? null
                        : _acceptTyped,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _passageCard(
    BuildContext context,
    TranscriptionDraft draft,
    int index,
  ) {
    final passage = draft.passages[index];
    final controller = _controllers.putIfAbsent(
      passage.partId,
      () => TextEditingController(text: passage.text),
    );
    final accepted = passage.feedbackAccepted;
    return Card(
      key: Key('transcription-passage-${passage.partId}'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('${index + 1}')),
                IconButton(
                  key: Key('transcription-up-${passage.partId}'),
                  tooltip: context.tr('transcriptionMoveUp'),
                  onPressed: _busy || index == 0
                      ? null
                      : () => _move(index, -1),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  key: Key('transcription-down-${passage.partId}'),
                  tooltip: context.tr('transcriptionMoveDown'),
                  onPressed: _busy || index == draft.passages.length - 1
                      ? null
                      : () => _move(index, 1),
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
            if (passage.uncertain)
              Text(
                context.tr('transcriptionUncertain'),
                key: Key('transcription-uncertain-${passage.partId}'),
              ),
            if (passage.keepAsInk)
              Text(
                context.tr('transcriptionKeptAsInk'),
                key: Key('transcription-kept-ink-${passage.partId}'),
              )
            else ...[
              TextField(
                key: Key('transcription-text-${passage.partId}'),
                controller: controller,
                enabled: !_busy && !accepted && !_sourceChanged,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: context.tr('transcriptionResult'),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  AppButton(
                    key: Key('transcription-accept-text-${passage.partId}'),
                    label: accepted
                        ? context.tr('transcriptionTextAccepted')
                        : context.tr('transcriptionAcceptText'),
                    onPressed: _busy || accepted || _sourceChanged
                        ? null
                        : () => _acceptText(passage),
                  ),
                  if (passage.kind == TranscriptionPassageKind.inkFallback)
                    AppButton(
                      key: Key('transcription-keep-ink-${passage.partId}'),
                      label: context.tr('transcriptionKeepInk'),
                      onPressed: _busy || accepted || _sourceChanged
                          ? null
                          : () => _keepInk(passage),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _sourceLabel(String id) {
    final item = _itemsById[id];
    if (item == null) return id;
    final kind = item['kind'];
    return kind is String ? '$kind · $id' : id;
  }
}
