import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/installed_account.dart';
import '../../../../domain/services/note_autosave.dart';
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
  bool _missing = false;
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
      _handler = PaperHandler.open(note, NoteAutosave(workspace.store));
    });
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
              child: track(
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
