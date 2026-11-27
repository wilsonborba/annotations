import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';

import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/services/content_job_service.dart';
import '../../components/scope.dart';

final class ContentJobReviewAccess {
  const ContentJobReviewAccess({required this.service});

  final ContentJobService service;
}

/// The optional content-job review surface. The host supplies an enabled
/// service only from an explicitly released runtime; the service itself stays
/// off by default.
class ContentJobReviewPage extends StatefulWidget {
  const ContentJobReviewPage({
    super.key,
    required this.noteId,
    required this.service,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
    required this.insertText,
    this.pickFiles,
    this.readFileForTesting,
    this.fileLengthForTesting,
  });

  final String noteId;
  final ContentJobService service;
  final bool Function() isOwnerScopeCurrent;
  final ValueListenable<int> ownerScopeRevision;
  final int expectedOwnerScopeRevision;
  final Future<bool> Function(String jobId, String text) insertText;
  final Future<List<fs.XFile>> Function()? pickFiles;

  /// Lets widget tests supply bytes without invoking the platform file API.
  @visibleForTesting
  final Future<List<int>> Function(fs.XFile file)? readFileForTesting;

  @visibleForTesting
  final Future<int> Function(fs.XFile file)? fileLengthForTesting;

  @override
  State<ContentJobReviewPage> createState() => _ContentJobReviewPageState();
}

class _ContentJobReviewPageState extends State<ContentJobReviewPage> {
  ContentJobReviewState _state = const ContentJobReviewState();
  ContentJobKind _kind = ContentJobKind.extraction;
  List<ContentJobSelectedFile> _selected = const [];
  String? _status;
  String? _error;
  bool _busy = true;
  bool _ownerExpired = false;
  int _flowGeneration = 0;

  String _failureText(Object error, String fallback) =>
      error is ApiError ? error.message : fallback;

  @override
  void initState() {
    super.initState();
    widget.ownerScopeRevision.addListener(_ownerScopeChanged);
    _reload();
  }

  void _ownerScopeChanged() {
    if (widget.ownerScopeRevision.value == widget.expectedOwnerScopeRevision &&
        widget.isOwnerScopeCurrent()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _state = const ContentJobReviewState();
      _selected = const [];
      _status = null;
      _error = context.tr('contentJobUnavailable');
      _busy = false;
      _ownerExpired = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    widget.ownerScopeRevision.removeListener(_ownerScopeChanged);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await widget.service.loadReviewState(widget.noteId);
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _state = state;
        _busy = false;
        _status = state.ref?.status;
        _kind = state.ref?.kind ?? _kind;
      });
    } on Object catch (error) {
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _busy = false;
        _error = _failureText(error, context.tr('contentJobUnavailable'));
      });
    }
  }

  Future<void> _chooseFiles() async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    try {
      final files =
          await (widget.pickFiles ??
              () => fs.openFiles(
                acceptedTypeGroups: const [
                  fs.XTypeGroup(
                    label: 'Media and documents',
                    extensions: [
                      'pdf',
                      'png',
                      'jpg',
                      'jpeg',
                      'webp',
                      'gif',
                      'mp3',
                      'wav',
                      'm4a',
                      'mp4',
                      'mov',
                      'webm',
                    ],
                  ),
                ],
              ))();
      if (!mounted || !widget.isOwnerScopeCurrent() || files.isEmpty) return;
      if (files.length > ContentJobService.maxSelectedFiles) {
        setState(() => _error = context.tr('contentJobTooManyFiles'));
        return;
      }
      final chosen = <ContentJobSelectedFile>[];
      for (final file in files) {
        if (file.name.runes.length > ContentJobService.maxFilenameCharacters) {
          setState(() => _error = context.tr('contentJobFilenameTooLong'));
          return;
        }
        final size =
            await (widget.fileLengthForTesting ??
                (selected) => selected.length())(file);
        if (!mounted || !widget.isOwnerScopeCurrent()) return;
        if (size > ContentJobService.maxFileBytes) {
          setState(() => _error = context.tr('contentJobFileTooLarge'));
          return;
        }
        chosen.add(
          ContentJobSelectedFile(
            filename: file.name,
            contentType: _contentType(file.name),
            size: size,
            readBytes: () =>
                (widget.readFileForTesting ??
                (selected) => _readBoundedFile(selected))(file),
          ),
        );
      }
      setState(() {
        _selected = chosen;
        _error = null;
      });
    } on Object catch (error) {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(
          () => _error = _failureText(
            error,
            context.tr('contentJobSelectionFailed'),
          ),
        );
      }
    }
  }

  String _contentType(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'm4a' => 'audio/mp4',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _start() async {
    if (_busy || _selected.isEmpty || !widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = context.tr('contentJobStarting');
    });
    try {
      final ref = await widget.service.startExplicitJob(
        noteId: widget.noteId,
        kind: _kind,
        selectedFiles: _selected,
      );
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _state = ContentJobReviewState(ref: ref);
        _busy = false;
        _status = ref.status;
      });
      await _resume();
    } on Object catch (error) {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = _failureText(error, context.tr('contentJobStartFailed'));
        });
      }
    }
  }

  Future<void> _resume() async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    final flow = ++_flowGeneration;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final draft = await widget.service.resumeJob(
        widget.noteId,
        onProgress: (sequence, status) {
          if (flow != _flowGeneration ||
              !mounted ||
              !widget.isOwnerScopeCurrent()) {
            return;
          }
          setState(() => _status = status);
        },
      );
      if (flow != _flowGeneration ||
          !mounted ||
          !widget.isOwnerScopeCurrent()) {
        return;
      }
      setState(() {
        _state = ContentJobReviewState(ref: _state.ref, draft: draft);
        _busy = false;
        _status = draft == null
            ? (_state.ref?.status ?? _status)
            : context.tr('contentJobReviewResult');
      });
    } on Object catch (error) {
      if (flow == _flowGeneration && mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = _failureText(error, context.tr('contentJobResumeFailed'));
        });
      }
    }
  }

  Future<void> _cancel() async {
    if (!widget.isOwnerScopeCurrent()) return;
    final flow = ++_flowGeneration;
    setState(() {
      _busy = true;
      _error = null;
      _status = context.tr('contentJobCancelling');
    });
    try {
      final draft = await widget.service.cancelJob(widget.noteId);
      if (flow != _flowGeneration ||
          !mounted ||
          !widget.isOwnerScopeCurrent()) {
        return;
      }
      final next = await widget.service.loadReviewState(widget.noteId);
      if (flow != _flowGeneration ||
          !mounted ||
          !widget.isOwnerScopeCurrent()) {
        return;
      }
      setState(() {
        _state = ContentJobReviewState(
          ref: next.ref,
          draft: draft ?? next.draft,
        );
        _busy = false;
        _status = next.ref?.status;
      });
    } on Object catch (error) {
      if (flow == _flowGeneration && mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = _failureText(error, context.tr('contentJobCancelFailed'));
        });
      }
    }
  }

  Future<void> _insert(ContentJobDraft draft) async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await widget.insertText(draft.jobId, draft.extractedText)) {
        throw StateError('The result could not be inserted into this note.');
      }
      await widget.service.markDraftInserted(widget.noteId, draft.jobId);
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      final next = await widget.service.loadReviewState(widget.noteId);
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _state = next;
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = _failureText(error, context.tr('contentJobInsertFailed'));
        });
      }
    }
  }

  Future<void> _discard(ContentJobDraft draft) async {
    if (_busy || !widget.isOwnerScopeCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.discardDraft(widget.noteId, draft.jobId);
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      final next = await widget.service.loadReviewState(widget.noteId);
      if (!mounted || !widget.isOwnerScopeCurrent()) return;
      setState(() {
        _state = next;
        _busy = false;
      });
    } on Object catch (error) {
      if (mounted && widget.isOwnerScopeCurrent()) {
        setState(() {
          _busy = false;
          _error = _failureText(error, context.tr('contentJobDiscardFailed'));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerExpired) {
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('contentJobTitle'))),
        body: Center(child: Text(context.tr('contentJobUnavailable'))),
      );
    }
    final draft = _state.draft;
    final ref = _state.ref;
    final resultHandled =
        ref?.status == 'result_inserted' || ref?.status == 'result_discarded';
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('contentJobTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(_error!, key: const Key('content-job-error')),
            ),
          if (ref?.errorMessage != null)
            Semantics(
              liveRegion: true,
              child: Text(
                '${context.tr('contentJobBackendError')}: ${ref!.errorMessage}',
                key: const Key('content-job-backend-error'),
              ),
            ),
          if (draft != null && !draft.accepted) ...[
            Text(context.tr('contentJobResultTitle')),
            const SizedBox(height: 8),
            SelectableText(
              draft.extractedText,
              key: const Key('content-job-result'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const Key('content-job-insert'),
                  onPressed: _busy ? null : () => _insert(draft),
                  child: Text(context.tr('contentJobInsert')),
                ),
                OutlinedButton(
                  key: const Key('content-job-discard'),
                  onPressed: _busy ? null : () => _discard(draft),
                  child: Text(context.tr('contentJobDiscard')),
                ),
              ],
            ),
          ] else if (draft?.accepted == true || resultHandled) ...[
            Text(
              ref?.status == 'result_discarded'
                  ? context.tr('contentJobResultDiscarded')
                  : context.tr('contentJobAlreadyInserted'),
            ),
            ..._fileSelectionControls(context),
          ] else if (ref != null && ref.jobId == null) ...[
            Text('${context.tr('contentJobStatus')}: ${_status ?? ref.status}'),
            const SizedBox(height: 8),
            ..._fileSelectionControls(context),
          ] else if (ref != null &&
              ref.jobId != null &&
              ContentJobService.isActiveStatus(ref.status)) ...[
            Text('${context.tr('contentJobStatus')}: ${_status ?? ref.status}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('content-job-resume'),
                  onPressed: _busy ? null : _resume,
                  child: Text(context.tr('contentJobResume')),
                ),
                OutlinedButton(
                  key: const Key('content-job-cancel'),
                  // Cancellation is deliberately available while SSE resume
                  // is busy; it is a separate, owner-fenced request.
                  onPressed: widget.isOwnerScopeCurrent() ? _cancel : null,
                  child: Text(context.tr('contentJobCancel')),
                ),
              ],
            ),
          ] else if (ref != null) ...[
            Text('${context.tr('contentJobStatus')}: ${_status ?? ref.status}'),
            const SizedBox(height: 8),
            ..._fileSelectionControls(context),
          ] else
            ..._fileSelectionControls(context),
          if (_status != null && (ref != null || _busy))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '${context.tr('contentJobStatus')}: $_status',
                  key: const Key('content-job-progress'),
                ),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }

  List<Widget> _fileSelectionControls(BuildContext context) => [
    DropdownButtonFormField<ContentJobKind>(
      key: const Key('content-job-kind'),
      initialValue: _kind,
      decoration: InputDecoration(labelText: context.tr('contentJobKind')),
      items: [
        for (final kind in ContentJobKind.values)
          DropdownMenuItem(
            value: kind,
            child: Text(
              context.tr(
                kind == ContentJobKind.extraction
                    ? 'contentJobExtraction'
                    : 'contentJobStudyNotes',
              ),
            ),
          ),
      ],
      onChanged: _busy ? null : (value) => setState(() => _kind = value!),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      key: const Key('content-job-select-files'),
      onPressed: _busy ? null : _chooseFiles,
      icon: const Icon(Icons.attach_file),
      label: Text(context.tr('contentJobSelectFiles')),
    ),
    for (final file in _selected)
      ListTile(
        dense: true,
        leading: const Icon(Icons.insert_drive_file_outlined),
        title: Text(file.filename),
        subtitle: Text('${file.size ?? file.bytes?.length ?? 0} bytes'),
      ),
    FilledButton(
      key: const Key('content-job-start'),
      onPressed: _busy || _selected.isEmpty ? null : _start,
      child: Text(
        context.tr(
          _state.ref?.jobId == null && _state.ref != null
              ? 'contentJobContinueUpload'
              : 'contentJobStart',
        ),
      ),
    ),
  ];
}

Future<List<int>> _readBoundedFile(fs.XFile file) async {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in file.openRead()) {
    length += chunk.length;
    if (length > ContentJobService.maxFileBytes) {
      throw StateError('Each selected file must be 100 MB or less.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
