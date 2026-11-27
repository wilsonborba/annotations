import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/features.dart';
import '../../../../core/note_limits.dart';
import '../../../../core/tracking_manifest.dart';
import '../../../../dal/remote/api_adapter.dart';
import '../../../../dal/remote/reports_api_adapter.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/models/reports_embed_data.dart';
import '../../../../domain/services/certifications_browser_handoff.dart';
import '../../../../domain/services/installed_account.dart';
import '../../../../domain/services/local_note_store.dart';
import '../../../../domain/services/note_autosave.dart';
import '../../../../domain/services/note_history.dart'
    show CommandKind, HistoryCommand;
import '../../../../domain/services/note_reports_service.dart';
import '../../../../domain/services/native_auth_service.dart';
import '../../../../domain/services/prepared_certification_service.dart';
import '../../../../domain/services/quiz_card_service.dart';
import '../../../../domain/services/reports_embed_source.dart';
import '../../../../domain/services/reports_chart_data.dart';
import '../../../../domain/services/reports_xlsx_data.dart';
import '../../../../domain/services/task_card_service.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../handlers/attachment_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/export_handler.dart';
import '../../handlers/reports_pdf_capture.dart';
import '../export/export_dialog.dart';
import '../../components/reports_search_dialog.dart';
import '../../components/reports_create_dialog.dart';
import '../../components/task_card_picker.dart';
import '../typed/note_screen.dart';
import 'transcription_review_page.dart';
import 'content_job_review_page.dart';

/// `/v1/write/<id>`: one local note in the editor of this platform.
class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.noteId,
    this.transcriptionReviewForTesting,
    this.contentJobsForTesting,
  });

  final String noteId;

  /// Fixture-only injection while no reviewed runtime is released. The
  /// production entry remains hidden with [FeatureSwitches.transcription].
  @visibleForTesting
  final TranscriptionReviewAccess? transcriptionReviewForTesting;

  /// Fixture-only optional adapter while Cortex content jobs remain off by
  /// default and no runtime activation is released.
  @visibleForTesting
  final ContentJobReviewAccess? contentJobsForTesting;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage>
    with WidgetsBindingObserver {
  PaperHandler? _handler;
  LocalNote? _note;
  bool _missing = false;
  bool _preparingQuiz = false;
  InstalledAccount? _installed;
  ReportsEmbedSource? _reportsSource;
  InstalledAccount? _reportsSourceInstalled;
  NativeSession? _reportsSourceSession;
  String? _reportsSourceAccountId;
  ExportHandler? _activeExport;
  int _openGeneration = 0;
  final ValueNotifier<int> _reportsOwnerScopeRevision = ValueNotifier(0);
  int _returnCheckSerial = 0;
  _PreparedQuizReturn? _pendingQuizReturn;
  bool _hasOpened = false;

  String _newCardId() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  bool _reportsOwnerIsCurrent({
    required int generation,
    required PaperHandler handler,
    required LocalNote note,
    required InstalledAccount installed,
    required NativeSession session,
  }) =>
      mounted &&
      generation == _openGeneration &&
      identical(handler, _handler) &&
      identical(note, _note) &&
      identical(installed, _installed) &&
      identical(session, installed.activeSession) &&
      installed.signedIn &&
      note.accountId != null &&
      note.accountId == installed.userId &&
      session.verifiedUserId == note.accountId;

  Future<void> _addReportsCard(
    BuildContext dialogContext,
    PaperHandler handler,
    AttachmentHandler attachments,
  ) async {
    final note = _note;
    final installed = _installed;
    final source = _reportsSource;
    final session = installed?.activeSession;
    if (note == null ||
        installed == null ||
        source == null ||
        session == null) {
      return;
    }
    final generation = _openGeneration;
    bool current() => _reportsOwnerIsCurrent(
      generation: generation,
      handler: handler,
      note: note,
      installed: installed,
      session: session,
    );
    if (!current()) return;
    try {
      final language = AppScope.of(dialogContext).preferences.locale;
      final project = await showReportsProjectPicker(
        dialogContext,
        source: source,
        language: language,
        isOwnerScopeCurrent: current,
        ownerScopeRevision: _reportsOwnerScopeRevision,
        expectedOwnerScopeRevision: generation,
      );
      if (!current() || project == null || !dialogContext.mounted) return;
      final reference = await showReportsSearchDialog(
        dialogContext,
        source: source,
        project: project.slug,
        language: language,
        isOwnerScopeCurrent: current,
        ownerScopeRevision: _reportsOwnerScopeRevision,
        expectedOwnerScopeRevision: generation,
      );
      if (!current() || reference == null) return;

      final width = math.min(360.0, math.max(1.0, handler.pageWidth - 48));
      final item = <String, Object?>{
        'id': _newCardId(),
        'kind': 'reports_embed',
        'width': width,
        'height': 224,
        ...reference.toDocumentFields(),
      };
      if (!attachments.addStructuredCard(item)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('reportsSearchError'))),
          );
        }
        return;
      }
      await handler.autosave.flush();
    } on Object {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('reportsSearchError'))),
        );
      }
    }
  }

  Future<void> _addTaskCard(
    BuildContext dialogContext,
    PaperHandler handler,
    AttachmentHandler attachments,
  ) async {
    final note = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    if (note == null || installed == null || session == null) return;

    final generation = _openGeneration;
    bool current() =>
        mounted &&
        generation == _openGeneration &&
        identical(handler, _handler) &&
        identical(note, _note) &&
        identical(installed, _installed) &&
        identical(session, installed.activeSession) &&
        installed.signedIn &&
        note.accountId != null &&
        note.accountId == installed.userId &&
        note.accountId == installed.localOwnerId &&
        session.verifiedUserId == note.accountId;

    if (!current()) return;
    final service = TaskCardService(
      ApiAdapter(client: SessionClient(installed, installed.client)),
    );
    try {
      final firstPage = await service.listOwnTaskPage();
      if (!current() || !dialogContext.mounted) return;
      final task = await showTaskCardPicker(
        dialogContext,
        tasks: firstPage.items,
        nextCursor: firstPage.nextCursor,
        createTask:
            ({required title, description, dueDate, required completed}) async {
              if (!current()) throw StateError('The active note changed.');
              final created = await service.createTask(
                title: title,
                description: description,
                dueDate: dueDate,
                completed: completed,
                isInstant: false,
              );
              if (!current()) throw StateError('The active note changed.');
              return created;
            },
        loadTaskPage: ({String? cursor}) async {
          if (!current()) throw StateError('The active note changed.');
          final refreshed = await service.listOwnTaskPage(cursor: cursor);
          if (!current()) throw StateError('The active note changed.');
          return refreshed;
        },
        isOwnerScopeCurrent: current,
        ownerScopeRevision: _reportsOwnerScopeRevision,
        expectedOwnerScopeRevision: generation,
      );
      if (!current() || task == null) return;

      final item = <String, Object?>{
        'id': _newCardId(),
        'kind': 'task_card',
        'width': math.min(360.0, math.max(1.0, handler.pageWidth - 48)),
        'height': 160,
        'task_id': task.taskId,
      };
      if (!attachments.addStructuredCard(item)) {
        if (mounted && current()) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('taskUnavailable'))),
          );
        }
      }
    } on Object {
      if (mounted && current()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('taskUnavailable'))));
      }
    }
  }

  Future<void> _createReportsChart(
    BuildContext dialogContext,
    PaperHandler handler,
    AttachmentHandler attachments,
  ) async {
    final note = _note;
    final installed = _installed;
    final source = _reportsSource;
    final session = installed?.activeSession;
    final serverNoteId = note?.serverNoteId;
    if (note == null ||
        installed == null ||
        source == null ||
        session == null ||
        serverNoteId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('reportsCreateRequiresSavedNote'))),
        );
      }
      return;
    }
    final generation = _openGeneration;
    bool current() => _reportsOwnerIsCurrent(
      generation: generation,
      handler: handler,
      note: note,
      installed: installed,
      session: session,
    );
    if (!current()) return;
    try {
      final language = AppScope.of(dialogContext).preferences.locale;
      final project = await showReportsProjectPicker(
        dialogContext,
        source: source,
        language: language,
        isOwnerScopeCurrent: current,
        ownerScopeRevision: _reportsOwnerScopeRevision,
        expectedOwnerScopeRevision: generation,
      );
      if (!current() || project == null || !dialogContext.mounted) return;
      final templates = await source.templatesForProject(
        project.slug,
        language: language,
      );
      if (!current()) return;
      final tables = await _reportsChartTables(handler);
      if (!current() || !dialogContext.mounted) return;

      Future<ReportsEmbedReference> create({
        required Map<String, Object?> item,
        required String operationKey,
      }) async {
        if (!current()) throw StateError('The active note changed.');
        final service = NoteReportsService(
          api: ApiAdapter(client: SessionClient(installed, installed.client)),
          session: session,
        );
        return service.createChart(
          serverNoteId: serverNoteId,
          project: project.slug,
          operationKey: operationKey,
          item: item,
        );
      }

      final reference = await showReportsCreateDialog(
        dialogContext,
        projectName: project.name,
        templates: templates,
        tables: tables,
        create: create,
        isOwnerScopeCurrent: current,
        ownerScopeRevision: _reportsOwnerScopeRevision,
        expectedOwnerScopeRevision: generation,
      );
      if (!current() || reference == null) return;
      final item = <String, Object?>{
        'id': _newCardId(),
        'kind': 'reports_embed',
        'width': math.min(360.0, math.max(1.0, handler.pageWidth - 48)),
        'height': 224,
        ...reference.toDocumentFields(),
      };
      if (!attachments.addStructuredCard(item)) {
        throw StateError(
          'The report was created but the note card could not be placed.',
        );
      }
      await handler.autosave.flush();
    } on Object {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('reportsCreateFailed'))),
        );
      }
    }
  }

  Future<List<ReportsChartSourceTable>> _reportsChartTables(
    PaperHandler handler,
  ) async {
    final document = handler.document;
    if (document is! PaperDocument) return const [];
    final tables = <ReportsChartSourceTable>[];
    final seen = <String>{};
    for (final item in document.itemsJson) {
      final kind = item['kind'];
      if (kind != 'csv_table' && kind != 'file_card') continue;
      final fileId = item['file_id'];
      if (fileId is! String || !seen.add(fileId)) continue;
      final file = await handler.autosave.files.attachment(fileId);
      if (file == null) {
        if (kind == 'csv_table') {
          throw const FormatException('The selected table file is missing.');
        }
        continue;
      }
      if (kind == 'file_card' && !file.name.toLowerCase().endsWith('.xlsx')) {
        continue;
      }
      final bytes = await handler.autosave.files.readAttachment(fileId);
      if (bytes == null) {
        throw const FormatException('The selected table file cannot be read.');
      }
      if (kind == 'csv_table') {
        tables.add(
          ReportsChartSourceTable.parse(
            fileId: fileId,
            name: file.name,
            bytes: bytes,
          ),
        );
      } else {
        tables.addAll(
          ReportsXlsxData.parse(fileId: fileId, name: file.name, bytes: bytes),
        );
      }
    }
    return List.unmodifiable(tables);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final pending = _pendingQuizReturn;
    if (pending == null) return;
    _pendingQuizReturn = null;
    unawaited(_checkPreparedQuizReturn(pending));
  }

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
    _reportsOwnerScopeRevision.value = generation;
    _pendingQuizReturn = null;
    final reportsSource = _reportsSource;
    final clearReportsSource =
        reportsSource != null &&
        (!identical(_reportsSourceInstalled, _installed) ||
            !identical(_reportsSourceSession, _installed?.activeSession));
    final reportsSourceToClear = clearReportsSource ? reportsSource : null;
    if (clearReportsSource) {
      _reportsSource = null;
      _reportsSourceInstalled = null;
      _reportsSourceSession = null;
      _reportsSourceAccountId = null;
    }
    final activeExport = _activeExport;
    activeExport?.invalidate();
    _activeExport = null;
    if (activeExport != null && mounted) {
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) navigator.pop();
    }
    final prior = _handler;
    _handler = null;
    _note = null;
    _missing = false;
    if (mounted) setState(() {});
    if (reportsSourceToClear != null) {
      await reportsSourceToClear.clearRestrictedCache();
    }
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
        await _continueInBrowser(
          saved.id,
          session,
          installed: installed,
          note: latest,
          generation: generation,
          isCurrent: isCurrent,
        );
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
      final returnNote = withStudy ?? await workspace.store.load(current.id);
      if (!isCurrent() || returnNote == null) return;
      await _continueInBrowser(
        saved.id,
        session,
        installed: installed,
        note: returnNote,
        generation: generation,
        isCurrent: isCurrent,
      );
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
    required InstalledAccount installed,
    required LocalNote note,
    required int generation,
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
      if (isCurrent()) {
        _pendingQuizReturn = _PreparedQuizReturn(
          serial: ++_returnCheckSerial,
          studyId: studyId,
          installed: installed,
          session: session,
          noteId: note.id,
          ownerId: session.verifiedUserId!,
          serverNoteId: note.serverNoteId!,
          serverRevision: note.serverRevision!,
          localRevision: note.revision,
          generation: generation,
        );
      }
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

  bool _isCurrentQuizReturn(_PreparedQuizReturn pending) {
    final active = pending.installed.activeSession;
    return mounted &&
        pending.serial == _returnCheckSerial &&
        pending.generation == _openGeneration &&
        identical(_installed, pending.installed) &&
        pending.installed.signedIn &&
        pending.installed.localOwnerId == pending.ownerId &&
        active != null &&
        active.sessionId == pending.session.sessionId &&
        active.csrfToken == pending.session.csrfToken &&
        active.verifiedUserId == pending.ownerId &&
        widget.noteId == pending.noteId &&
        _note?.id == pending.noteId &&
        _handler != null;
  }

  bool _matchesQuizReturnNote(LocalNote? note, _PreparedQuizReturn pending) =>
      note != null &&
      note.id == pending.noteId &&
      note.revision == pending.localRevision &&
      note.accountId == pending.ownerId &&
      note.serverNoteId == pending.serverNoteId &&
      note.serverRevision == pending.serverRevision &&
      note.preparedStudyId == pending.studyId;

  Future<void> _checkPreparedQuizReturn(_PreparedQuizReturn pending) async {
    final handler = _handler;
    final scope = AppScope.of(context);
    final workspace = scope.workspace;
    final api = scope.service.api;
    if (!_isCurrentQuizReturn(pending) ||
        handler == null ||
        workspace == null) {
      return;
    }
    try {
      await handler.autosave.flush();
      if (!_isCurrentQuizReturn(pending)) return;
      final before = await workspace.store.load(pending.noteId);
      if (!_isCurrentQuizReturn(pending) ||
          !_matchesQuizReturnNote(before, pending)) {
        return;
      }
      final study = await PreparedCertificationService(
        api: api,
        session: pending.session,
      ).read(pending.studyId);
      final quizId = study.quizId;
      if (!_isCurrentQuizReturn(pending) || quizId == null) return;

      await handler.autosave.flush();
      if (!_isCurrentQuizReturn(pending)) return;
      final current = await workspace.store.load(pending.noteId);
      if (!_isCurrentQuizReturn(pending) ||
          !_matchesQuizReturnNote(current, pending)) {
        return;
      }
      final document = handler.document;
      if (document is! PaperDocument) return;
      final existing = document.itemsJson.cast<Map<String, Object?>>().where(
        (item) =>
            item['kind'] == 'quiz_card' &&
            (item['study_id'] == pending.studyId || item['quiz_id'] == quizId),
      );
      final Map<String, Object?> operation;
      final match = existing.firstOrNull;
      if (match != null) {
        if (match['study_id'] == pending.studyId &&
            match['quiz_id'] == quizId) {
          return;
        }
        operation = {
          'op': 'update',
          'id': match['id'],
          'changes': {'study_id': pending.studyId, 'quiz_id': quizId},
        };
      } else {
        final width = math.max(
          EditorGrid.cell,
          math.min(320, EditorGrid.floor(handler.pageWidth)),
        );
        final x = EditorGrid.floor((handler.pageWidth - width) / 2);
        final y = EditorGrid.ceil(
          handler.page.contentBottom(document) + EditorGrid.cell,
        );
        operation = {
          'op': 'add',
          'item': {
            'id':
                'quiz-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
            'kind': 'quiz_card',
            'x': x,
            'y': y,
            'width': width,
            'height': 120,
            'study_id': pending.studyId,
            'quiz_id': quizId,
          },
        };
      }
      final decision = handler.apply(
        HistoryCommand(CommandKind.card),
        (rules, document) => rules.check(document, operation),
      );
      if (!decision.accepted) return;
      await handler.autosave.flush();
    } on Object {
      // A failed status read leaves the local note unchanged; Continue can
      // perform another one-shot check on the next browser return.
    }
  }

  Future<QuizSummary?> _loadQuizCard(String quizId) async {
    final note = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    if (!mounted ||
        note == null ||
        installed == null ||
        !installed.signedIn ||
        note.accountId == null ||
        note.accountId != installed.userId ||
        note.accountId != installed.localOwnerId ||
        session == null ||
        session.verifiedUserId != note.accountId) {
      return null;
    }
    return QuizCardService(
      ApiAdapter(client: SessionClient(installed, installed.client)),
    ).readOwnerSummary(quizId);
  }

  bool _hasTrustedOwnerSession() {
    final note = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    return mounted &&
        note?.accountId != null &&
        installed != null &&
        installed.signedIn &&
        note!.accountId == installed.userId &&
        note.accountId == installed.localOwnerId &&
        session != null &&
        session.verifiedUserId == note.accountId;
  }

  Future<void> _openTranscriptionReview() async {
    final access = widget.transcriptionReviewForTesting;
    final handler = _handler;
    final noteBefore = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    final workspace = AppScope.of(context).workspace;
    final generation = _openGeneration;
    if (access == null ||
        handler == null ||
        noteBefore == null ||
        workspace == null ||
        installed == null ||
        session == null ||
        !_hasTrustedOwnerSession() ||
        noteBefore.document.schema.family != DocumentFamily.original) {
      return;
    }
    bool isCurrent() =>
        mounted &&
        generation == _openGeneration &&
        identical(handler, _handler) &&
        identical(noteBefore, _note) &&
        identical(installed, _installed) &&
        identical(session, installed.activeSession) &&
        identical(workspace, AppScope.of(context).workspace) &&
        installed.signedIn &&
        session.verifiedUserId == noteBefore.accountId &&
        noteBefore.accountId == installed.userId &&
        noteBefore.accountId == installed.localOwnerId;

    if (!isCurrent()) return;
    await handler.autosave.flush();
    if (!isCurrent()) return;
    final currentNote = await workspace.loadNoteForAccount(
      noteBefore.id,
      installed.localOwnerId,
    );
    if (!mounted ||
        !isCurrent() ||
        currentNote == null ||
        currentNote.accountId != noteBefore.accountId) {
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => TranscriptionReviewPage(
          note: currentNote,
          access: access,
          store: workspace.store,
          ownerAccountId: noteBefore.accountId!,
          initialSelectedItemIds: handler.selection.value.ids,
          isOwnerScopeCurrent: isCurrent,
        ),
      ),
    );
  }

  Future<void> _openContentJobs() async {
    final access = widget.contentJobsForTesting;
    final handler = _handler;
    final note = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    final workspace = AppScope.of(context).workspace;
    final generation = _openGeneration;
    if (access == null ||
        !access.service.enabled ||
        handler == null ||
        note == null ||
        workspace == null ||
        installed == null ||
        session == null ||
        note.document.schema.family != DocumentFamily.original ||
        !_hasTrustedOwnerSession()) {
      return;
    }
    bool isCurrent() =>
        mounted &&
        generation == _openGeneration &&
        identical(handler, _handler) &&
        identical(note, _note) &&
        identical(installed, _installed) &&
        identical(session, installed.activeSession) &&
        identical(workspace, AppScope.of(context).workspace) &&
        installed.signedIn &&
        session.verifiedUserId == note.accountId &&
        note.accountId == installed.userId &&
        note.accountId == installed.localOwnerId;

    if (!isCurrent()) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ContentJobReviewPage(
          noteId: note.id,
          service: access.service,
          isOwnerScopeCurrent: isCurrent,
          ownerScopeRevision: _reportsOwnerScopeRevision,
          expectedOwnerScopeRevision: generation,
          insertText: (jobId, text) async {
            if (!isCurrent()) return false;
            if (handler.autosave.state.value == SaveState.failed) {
              await handler.autosave.retry();
              if (!isCurrent() ||
                  handler.autosave.state.value != SaveState.saved) {
                return false;
              }
            }
            if (!handler.insertContentJobText(jobId, text)) return false;
            await handler.autosave.flush();
            return isCurrent() &&
                handler.autosave.state.value == SaveState.saved;
          },
        ),
      ),
    );
  }

  ReportsEmbedSource? _reportsSourceFor(
    LocalNote note,
    InstalledAccount? installed,
  ) {
    final session = installed?.activeSession;
    final accountId = note.accountId;
    if (installed == null ||
        accountId == null ||
        accountId != installed.localOwnerId ||
        session?.verifiedUserId != accountId) {
      return null;
    }
    if (_reportsSource == null ||
        !identical(_reportsSourceInstalled, installed) ||
        !identical(_reportsSourceSession, session) ||
        _reportsSourceAccountId != accountId) {
      _reportsSource = ReportsEmbedSource(
        api: ReportsApiAdapter(
          headersProvider: ReportsApiAdapter.nativeSessionHeaders(
            installed.auth,
          ),
          client: installed.client,
        ),
        hasStoredViewerSession: () async {
          final stored = await installed.auth.storage.readSession();
          return stored?.verifiedUserId == accountId;
        },
      );
      _reportsSourceInstalled = installed;
      _reportsSourceSession = session;
      _reportsSourceAccountId = accountId;
    }
    return _reportsSource;
  }

  Future<TaskSummary?> _loadTaskCard(String taskId) async {
    final note = _note;
    final installed = _installed;
    final session = installed?.activeSession;
    if (!mounted ||
        note == null ||
        installed == null ||
        !installed.signedIn ||
        note.accountId == null ||
        note.accountId != installed.userId ||
        note.accountId != installed.localOwnerId ||
        session == null ||
        session.verifiedUserId != note.accountId) {
      return null;
    }
    final service = TaskCardService(
      ApiAdapter(client: SessionClient(installed, installed.client)),
    );
    const cardId = 'note-live-task-card';
    service.attachCard(cardId, taskId, isInstant: false);
    await service.refreshTask(taskId);
    return service.card(cardId)?.cached;
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
    _pendingQuizReturn = null;
    _activeExport?.invalidate();
    _activeExport = null;
    WidgetsBinding.instance.removeObserver(this);
    _reportsOwnerScopeRevision.dispose();
    _installed?.removeListener(_accountChanged);
    final handler = _handler;
    // Keep the last edit, then release the editor.
    handler?.autosave.flush().whenComplete(handler.autosave.dispose);
    handler?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final workspace = scope.workspace;
    final handler = _handler;
    final note = _note;
    final transcriptionAccess = widget.transcriptionReviewForTesting;
    final transcriptionEntryVisible =
        transcriptionAccess != null &&
        (FeatureSwitches.transcription || kDebugMode) &&
        note?.document.schema.family == DocumentFamily.original &&
        _hasTrustedOwnerSession();
    final contentJobsVisible =
        kDebugMode &&
        workspace != null &&
        note?.document.schema.family == DocumentFamily.original &&
        widget.contentJobsForTesting?.service.enabled == true &&
        _hasTrustedOwnerSession();
    final reportsSource = note == null
        ? null
        : _reportsSourceFor(note, _installed);
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
                  if (transcriptionEntryVisible)
                    track(
                      'workspace.note.convert_handwriting',
                      AppButton(
                        key: const Key('editor-convert-handwriting'),
                        label: context.tr('transcriptionConvert'),
                        onPressed: _openTranscriptionReview,
                      ),
                    ),
                  if (contentJobsVisible)
                    track(
                      'workspace.note.content_jobs',
                      AppButton(
                        key: const Key('editor-content-jobs'),
                        label: context.tr('contentJobTitle'),
                        onPressed: _openContentJobs,
                      ),
                    ),
                  if (handler != null && workspace != null)
                    track(
                      'workspace.note.export',
                      AppButton(
                        key: const Key('editor-export'),
                        label: context.tr('exportPdf'),
                        icon: AppIcons.download,
                        onPressed: () async {
                          final exportGeneration = _openGeneration;
                          final exportHandler = handler;
                          final exportNoteBeforeLoad = _note;
                          final exportNoteId = widget.noteId;
                          final exportWorkspace = workspace;
                          final exportScope = AppScope.of(context);
                          final exportInstalled = exportScope.installed;
                          final exportSession = exportInstalled?.activeSession;
                          bool exportEntryIsCurrent() {
                            if (!mounted ||
                                !context.mounted ||
                                _openGeneration != exportGeneration ||
                                !identical(_handler, exportHandler) ||
                                _note?.id != exportNoteBeforeLoad?.id ||
                                widget.noteId != exportNoteId ||
                                !identical(_installed, exportInstalled)) {
                              return false;
                            }
                            final currentScope = AppScope.of(context);
                            return identical(
                                  currentScope.workspace,
                                  exportWorkspace,
                                ) &&
                                identical(
                                  currentScope.installed,
                                  exportInstalled,
                                ) &&
                                (exportInstalled == null ||
                                    identical(
                                      exportInstalled.activeSession,
                                      exportSession,
                                    ));
                          }

                          if (!exportEntryIsCurrent()) return;
                          await handler.autosave.flush();
                          if (!exportEntryIsCurrent()) return;
                          final note = await workspace.store.load(exportNoteId);
                          if (!exportEntryIsCurrent()) return;
                          if (note == null ||
                              note.id != exportNoteId ||
                              note.accountId !=
                                  exportNoteBeforeLoad?.accountId) {
                            return;
                          }
                          if (!context.mounted) return;
                          final scope = AppScope.of(context);
                          final installed = exportInstalled;
                          final reportsSource = _reportsSourceFor(
                            note,
                            installed,
                          );
                          final taskCards =
                              installed != null &&
                                  installed.signedIn &&
                                  note.accountId == installed.userId
                              ? TaskCardService(
                                  ApiAdapter(
                                    client: SessionClient(
                                      installed,
                                      installed.client,
                                    ),
                                  ),
                                )
                              : null;
                          final quizCards =
                              installed != null &&
                                  installed.signedIn &&
                                  note.accountId != null &&
                                  note.accountId == installed.localOwnerId &&
                                  installed.activeSession?.verifiedUserId ==
                                      note.accountId &&
                                  note.accountId == installed.userId
                              ? QuizCardService(
                                  ApiAdapter(
                                    client: SessionClient(
                                      installed,
                                      installed.client,
                                    ),
                                  ),
                                )
                              : null;
                          bool exportQuizScopeIsCurrent() =>
                              mounted &&
                              _openGeneration == exportGeneration &&
                              identical(_installed, installed) &&
                              _note?.id == note.id &&
                              installed != null &&
                              installed.signedIn &&
                              note.accountId != null &&
                              note.accountId == installed.userId &&
                              note.accountId == installed.localOwnerId &&
                              identical(
                                installed.activeSession,
                                exportSession,
                              ) &&
                              exportSession?.verifiedUserId == note.accountId;
                          final language = scope.preferences.locale;
                          final export = ExportHandler(
                            note: note,
                            store: workspace.store,
                            untitledTitle: context.tr('untitledNote'),
                            loadReportsEmbed: reportsSource == null
                                ? null
                                : (item) async {
                                    if (installed == null ||
                                        note.accountId == null ||
                                        note.accountId !=
                                            installed.localOwnerId ||
                                        installed
                                                .activeSession
                                                ?.verifiedUserId !=
                                            note.accountId) {
                                      return const ReportsEmbedData(
                                        state: ReportsEmbedState.signInRequired,
                                        reference: null,
                                      );
                                    }
                                    return reportsSource.loadDocument(
                                      item,
                                      trustedAccountId: installed.userId,
                                      language: language,
                                    );
                                  },
                            renderReportsChart: (data, {required partial}) =>
                                captureReportsPdfChart(
                                  context,
                                  data,
                                  language: language,
                                ),
                            loadTaskSummary: taskCards == null
                                ? null
                                : (taskId) async {
                                    final cardId = 'pdf-export-$taskId';
                                    taskCards.attachCard(
                                      cardId,
                                      taskId,
                                      isInstant: false,
                                    );
                                    await taskCards.refreshTask(taskId);
                                    return taskCards.card(cardId)?.cached;
                                  },
                            loadQuizSummary: quizCards == null
                                ? null
                                : (quizId) async {
                                    if (!exportQuizScopeIsCurrent()) {
                                      return null;
                                    }
                                    final summary = await quizCards
                                        .readOwnerSummary(quizId);
                                    return exportQuizScopeIsCurrent()
                                        ? summary
                                        : null;
                                  },
                          );
                          if (!exportEntryIsCurrent()) {
                            export.dispose();
                            return;
                          }
                          if (!context.mounted) {
                            export.dispose();
                            return;
                          }
                          _activeExport?.invalidate();
                          _activeExport = export;
                          try {
                            await showExportDialog(context, export);
                          } finally {
                            if (identical(_activeExport, export)) {
                              _activeExport = null;
                            }
                            export.dispose();
                          }
                        },
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
                  : handler == null || workspace == null || note == null
                  ? const Center(child: CircularProgressIndicator())
                  : NoteScreen(
                      handler: handler,
                      profile: workspace.profile,
                      reportsSource: reportsSource,
                      trustedReportsAccountId: reportsSource == null
                          ? null
                          : note.accountId,
                      reportsLanguage: scope.preferences.locale,
                      onAddReport:
                          reportsSource != null &&
                              _installed?.signedIn == true &&
                              note.accountId == _installed?.userId
                          ? _addReportsCard
                          : null,
                      onAddTaskCard: _hasTrustedOwnerSession()
                          ? _addTaskCard
                          : null,
                      onCreateReport:
                          reportsSource != null && _hasTrustedOwnerSession()
                          ? _createReportsChart
                          : null,
                      loadQuizCard: _hasTrustedOwnerSession()
                          ? _loadQuizCard
                          : null,
                      loadTaskCard: _hasTrustedOwnerSession()
                          ? _loadTaskCard
                          : null,
                    ),
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

final class _PreparedQuizReturn {
  const _PreparedQuizReturn({
    required this.serial,
    required this.studyId,
    required this.installed,
    required this.session,
    required this.noteId,
    required this.ownerId,
    required this.serverNoteId,
    required this.serverRevision,
    required this.localRevision,
    required this.generation,
  });

  final int serial;
  final String studyId;
  final InstalledAccount installed;
  final NativeSession session;
  final String noteId;
  final String ownerId;
  final String serverNoteId;
  final int serverRevision;
  final int localRevision;
  final int generation;
}
