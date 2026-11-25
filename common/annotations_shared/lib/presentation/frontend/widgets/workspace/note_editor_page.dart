import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/features.dart';
import '../../../../core/tracking_manifest.dart';
import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../domain/services/certifications_browser_handoff.dart';
import '../../../../domain/services/installed_account.dart';
import '../../../../domain/services/local_note_store.dart';
import '../../../../domain/services/note_autosave.dart';
import '../../../../domain/services/native_auth_service.dart';
import '../../../../domain/services/prepared_certification_service.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../handlers/paper_handler.dart';
import '../typed/note_screen.dart';

/// `/v1/write/<id>`: one local note in the editor of this platform.
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  PaperHandler? _handler;
  LocalNote? _note;
  bool _missing = false;
  bool _preparingQuiz = false;
  InstalledAccount? _installed;
  int _openGeneration = 0;
  bool _hasOpened = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final installed = AppScope.of(context).installed;
    if (_hasOpened && identical(installed, _installed)) return;
    _hasOpened = true;
    _installed?.removeListener(_accountChanged);
    _installed = installed;
    _installed?.addListener(_accountChanged);
    _open();
  }

  void _accountChanged() => _open();

  Future<void> _open() async {
    final generation = ++_openGeneration;
    final prior = _handler;
    _handler = null;
    _note = null;
    _missing = false;
    if (mounted) setState(() {});
    if (prior != null) {
      await prior.autosave.flush();
      prior.autosave.dispose();
      prior.dispose();
    }
    if (!mounted || generation != _openGeneration) return;
    final scope = AppScope.of(context);
    final workspace = scope.workspace;
    final accountId = scope.installed?.localOwnerId;
    final note = await workspace?.loadNoteForAccount(widget.noteId, accountId);
    if (!mounted || generation != _openGeneration) return;
    if (workspace == null || note == null) {
      setState(() => _missing = true);
      return;
    }
    setState(() {
      _note = note;
      _handler = PaperHandler.open(note, NoteAutosave(workspace.store));
    });
  }

  Future<void> _prepareQuiz() async {
    if (_preparingQuiz) return;
    setState(() => _preparingQuiz = true);
    try {
      await _runPrepareQuiz();
    } finally {
      if (mounted) setState(() => _preparingQuiz = false);
    }
  }

  Future<void> _runPrepareQuiz() async {
    final scope = AppScope.of(context);
    final requiresSyncMessage = context.tr('quizRequiresSync');
    final noEligibleSourceMessage = context.tr('quizNoEligibleSource');
    final sourceLimitMessage = context.tr('quizSourceLimit');
    final prepareFailedMessage = context.tr('quizPrepareFailed');
    final openFailedMessage = context.tr('quizOpenFailed');
    final studyUnavailableMessage = context.tr('quizStudyUnavailable');
    final prepareFailedDialogMessage = context.tr('quizPrepareFailed');
    final handler = _handler;
    final note = _note;
    final generation = _openGeneration;
    final installed = _installed;
    final session = installed?.activeSession;
    final workspace = scope.workspace;
    bool isCurrent() =>
        installed != null &&
        session != null &&
        _isCurrentPrepare(generation, installed, session);
    if (handler == null ||
        note == null ||
        workspace == null ||
        installed == null ||
        session == null ||
        !installed.signedIn ||
        session.verifiedUserId == null ||
        note.accountId != session.verifiedUserId ||
        note.serverNoteId == null ||
        note.serverRevision == null ||
        note.syncState != LocalSyncState.synced) {
      _showMessage(requiresSyncMessage);
      return;
    }

    final latest = await workspace.store.load(note.id);
    if (!isCurrent()) return;
    if (latest == null ||
        latest.syncState != LocalSyncState.synced ||
        latest.accountId != session.verifiedUserId ||
        latest.serverNoteId == null ||
        latest.serverRevision == null) {
      _showMessage(requiresSyncMessage);
      return;
    }
    final service = PreparedCertificationService(
      api: scope.service.api,
      session: session,
    );
    PreparedCertificationNoteSourceCatalog catalog;
    try {
      catalog = await service.readNoteSourceCatalog(latest.serverNoteId!);
    } on ApiError catch (error) {
      if (!isCurrent()) return;
      final staleStudyId = latest.preparedStudyId;
      if (staleStudyId != null &&
          (error.status == 401 || error.status == 403 || error.status == 404)) {
        await workspace.store.clearPreparedStudyReference(
          latest.id,
          accountId: session.verifiedUserId!,
          serverNoteId: latest.serverNoteId!,
          studyId: staleStudyId,
        );
      }
      if (isCurrent()) {
        _showMessage(
          error.status == 401 || error.status == 403 || error.status == 404
              ? studyUnavailableMessage
              : prepareFailedDialogMessage,
        );
      }
      return;
    }
    if (!isCurrent()) return;
    if (catalog.revision != latest.serverRevision) {
      _showMessage(requiresSyncMessage);
      return;
    }
    final studyId = latest.preparedStudyId;
    if (studyId != null) {
      try {
        final saved = await service.read(studyId);
        if (!isCurrent()) return;
        if (saved.config == null) {
          _showMessage(prepareFailedDialogMessage);
          return;
        }
        await _continueInBrowser(saved.id, session, isCurrent: isCurrent);
      } on ApiError catch (error) {
        if (!isCurrent()) return;
        if (error.status == 401 || error.status == 403 || error.status == 404) {
          await workspace.store.clearPreparedStudyReference(
            latest.id,
            accountId: session.verifiedUserId!,
            serverNoteId: latest.serverNoteId!,
            studyId: studyId,
          );
          if (isCurrent()) _showMessage(studyUnavailableMessage);
        } else if (mounted) {
          _showMessage(prepareFailedDialogMessage);
        }
      } on Object {
        if (isCurrent()) _showMessage(prepareFailedDialogMessage);
      }
      return;
    }
    final options = await _quizSources(catalog, workspace.store);
    if (!isCurrent()) return;
    if (options.isEmpty) {
      _showMessage(noEligibleSourceMessage);
      return;
    }
    final choice = await _chooseQuizSources(
      latest,
      catalog.title,
      sourceLimitMessage,
      options,
    );
    if (!isCurrent() || choice == null) return;

    var prepared = false;
    try {
      await handler.autosave.flush();
      if (!isCurrent()) return;
      final current = await workspace.store.load(latest.id);
      if (!isCurrent()) return;
      if (current == null ||
          current.syncState != LocalSyncState.synced ||
          current.accountId != session.verifiedUserId ||
          current.serverRevision != latest.serverRevision ||
          current.serverNoteId != latest.serverNoteId) {
        _showMessage(requiresSyncMessage);
        return;
      }
      final selectedSources = <PreparedCertificationSource>[];
      for (final option in choice.sources) {
        final attachment = option.attachment;
        if (option.source != null) {
          selectedSources.add(option.source!);
          continue;
        }
        final bytes = attachment == null
            ? null
            : await workspace.store.readAttachment(attachment.id);
        if (!isCurrent()) return;
        final fileId = await service.prepareAttachmentSource(
          fileId: option.fileId!,
          attachment: attachment,
          bytes: bytes,
          isCurrent: isCurrent,
        );
        if (!isCurrent()) return;
        selectedSources.add(
          PreparedCertificationSource(kind: 'file', fileId: fileId),
        );
      }
      if (!isCurrent()) return;
      final study = await service.create(
        noteId: current.serverNoteId!,
        title: choice.title,
        expectedRevision: catalog.revision,
        sources: selectedSources,
        config: choice.config,
      );
      if (!isCurrent()) return;
      await workspace.store.savePreparedStudyReference(
        current.id,
        accountId: session.verifiedUserId!,
        serverNoteId: current.serverNoteId!,
        serverRevision: catalog.revision,
        studyId: study.id,
      );
      if (!isCurrent()) return;
      prepared = true;
      final withStudy = await workspace.store.load(current.id);
      if (!isCurrent()) return;
      if (mounted && withStudy != null) setState(() => _note = withStudy);
      final saved = await service.read(study.id);
      if (!isCurrent()) return;
      if (saved.config?.language != choice.config.language ||
          saved.config?.count != choice.config.count) {
        throw const PreparedCertificationPersistenceException();
      }
      await _continueInBrowser(saved.id, session, isCurrent: isCurrent);
    } on Object {
      if (isCurrent()) {
        _showMessage(prepared ? openFailedMessage : prepareFailedMessage);
      }
    }
  }

  bool _isCurrentPrepare(
    int generation,
    InstalledAccount installed,
    NativeSession session,
  ) {
    final active = installed.activeSession;
    return mounted &&
        generation == _openGeneration &&
        identical(_installed, installed) &&
        installed.signedIn &&
        active != null &&
        active.sessionId == session.sessionId &&
        active.csrfToken == session.csrfToken &&
        active.verifiedUserId == session.verifiedUserId;
  }

  Future<void> _continueInBrowser(
    String studyId,
    NativeSession session, {
    required bool Function() isCurrent,
  }) async {
    String? handoffId;
    try {
      if (!isCurrent()) return;
      final handoff = await CertificationsBrowserHandoffService().create(
        session: session,
        studyId: studyId,
      );
      handoffId = handoff.handoffId;
      if (!isCurrent()) {
        await _cancelHandoff(session, handoffId);
        return;
      }
      final opened = await launchUrl(
        handoff.launchUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('browser launch was not accepted');
    } on Object {
      if (handoffId != null) {
        await _cancelHandoff(session, handoffId);
      }
      rethrow;
    }
  }

  Future<void> _cancelHandoff(NativeSession session, String handoffId) async {
    try {
      await CertificationsBrowserHandoffService().cancel(
        session: session,
        handoffId: handoffId,
      );
    } on Object {
      // The continuation expires server-side if cancellation also fails.
    }
  }

  Future<List<_QuizSourceOption>> _quizSources(
    PreparedCertificationNoteSourceCatalog catalog,
    LocalNoteStore store,
  ) async {
    final options = <_QuizSourceOption>[];
    for (final source in catalog.noteSources) {
      final original = source.kind == 'note_original';
      options.add(
        _QuizSourceOption(
          id: source.kind,
          label: context.tr(original ? 'quizOriginal' : 'quizTyped'),
          source: source,
        ),
      );
    }
    var fileIndex = 0;
    final attachedFileLabel = context.tr('quizAttachedFile');
    for (final id in catalog.fileIds) {
      final attachment = await store.attachment(id);
      fileIndex++;
      options.add(
        _QuizSourceOption(
          id: 'file:$id',
          fileId: id,
          label: attachment?.name ?? '$attachedFileLabel $fileIndex',
          attachment: attachment,
        ),
      );
    }
    return options;
  }

  Future<
    ({
      String title,
      PreparedCertificationConfig config,
      List<_QuizSourceOption> sources,
    })?
  >
  _chooseQuizSources(
    LocalNote note,
    String? serverTitle,
    String sourceLimitMessage,
    List<_QuizSourceOption> options,
  ) {
    final selected = <String>{};
    final title = TextEditingController(
      text: serverTitle ?? note.title ?? 'Study',
    );
    var language = 'en';
    var count = 10;
    return showAppDialog<
          ({
            String title,
            PreparedCertificationConfig config,
            List<_QuizSourceOption> sources,
          })
        >(
          context,
          (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AppDialog(
              title: context.tr('prepareQuiz'),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .68,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(context.tr('quizSources')),
                      const SizedBox(height: 8),
                      Text(sourceLimitMessage),
                      const SizedBox(height: 8),
                      for (final option in options)
                        CheckboxListTile(
                          key: Key('quiz-source-${option.id}'),
                          value: selected.contains(option.id),
                          title: Text(option.label),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (value) => setDialogState(() {
                            if (value == true) {
                              selected.add(option.id);
                            } else {
                              selected.remove(option.id);
                            }
                          }),
                        ),
                      TextField(
                        key: const Key('quiz-study-title'),
                        controller: title,
                        decoration: InputDecoration(
                          labelText: context.tr('quizTitle'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('quiz-language'),
                        initialValue: language,
                        decoration: InputDecoration(
                          labelText: context.tr('quizLanguage'),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'en', child: Text('English')),
                          DropdownMenuItem(
                            value: 'pt-BR',
                            child: Text('Português (Brasil)'),
                          ),
                          DropdownMenuItem(value: 'th', child: Text('ไทย')),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => language = value ?? 'en'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: const Key('quiz-count'),
                        initialValue: count,
                        decoration: InputDecoration(
                          labelText: context.tr('quizQuestionCount'),
                        ),
                        items: [
                          for (var value = 1; value <= 20; value++)
                            DropdownMenuItem(
                              value: value,
                              child: Text('$value'),
                            ),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => count = value ?? 10),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                AppButton.subtle(
                  label: context.tr('cancel'),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
                AppButton.primary(
                  label: context.tr('quizBrowserContinue'),
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, (
                          title: title.text.trim().isEmpty
                              ? 'Study'
                              : title.text.trim(),
                          config: PreparedCertificationConfig(
                            language: language,
                            count: count,
                          ),
                          sources: [
                            for (final option in options)
                              if (selected.contains(option.id)) option,
                          ],
                        )),
                ),
              ],
            ),
          ),
        )
        .whenComplete(title.dispose);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _openGeneration++;
    _installed?.removeListener(_accountChanged);
    final handler = _handler;
    // Keep the last edit, then release the editor.
    handler?.autosave.flush().whenComplete(handler.autosave.dispose);
    handler?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = AppScope.of(context).workspace;
    final handler = _handler;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  track(
                    'workspace.note.back',
                    AppButton.subtle(
                      key: const Key('editor-back'),
                      label: context.tr('workspaceTitle'),
                      icon: AppIcons.chevronLeft,
                      onPressed: () async {
                        await _handler?.autosave.flush();
                        if (context.mounted) context.go('/v1/write');
                      },
                    ),
                  ),
                  const Spacer(),
                  if (workspace != null &&
                      Features(
                        workspace.profile,
                      ).isAvailable(Feature.quizPreparation))
                    track(
                      'workspace.note.prepare_quiz',
                      AppButton.primary(
                        key: const Key('editor-prepare-quiz'),
                        label: _note?.preparedStudyId == null
                            ? context.tr('prepareQuiz')
                            : context.tr('continueQuiz'),
                        onPressed: _preparingQuiz ? null : _prepareQuiz,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _missing
                  ? Center(
                      key: const Key('editor-missing'),
                      child: Text(context.tr('notFound')),
                    )
                  : handler == null || workspace == null
                  ? const Center(child: CircularProgressIndicator())
                  : NoteScreen(handler: handler, profile: workspace.profile),
            ),
          ],
        ),
      ),
    );
  }
}

final class _QuizSourceOption {
  const _QuizSourceOption({
    required this.id,
    required this.label,
    this.fileId,
    this.source,
    this.attachment,
  });

  final String id;
  final String label;
  final String? fileId;
  final PreparedCertificationSource? source;
  final LocalAttachment? attachment;
}
