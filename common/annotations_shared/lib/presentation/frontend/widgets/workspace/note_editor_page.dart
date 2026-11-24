import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/note_autosave.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../handlers/paper_handler.dart';
import '../export/export_dialog.dart';
import '../typed/note_screen.dart';
import '../../handlers/export_handler.dart';

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
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _open();
  }

  Future<void> _open() async {
    final workspace = AppScope.of(context).workspace;
    final note = await workspace?.store.load(widget.noteId);
    if (!mounted) return;
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
                  if (handler != null && workspace != null)
                    track(
                      'workspace.note.export',
                      AppButton(
                        key: const Key('editor-export'),
                        label: context.tr('exportPdf'),
                        icon: AppIcons.download,
                        onPressed: () async {
                          await handler.autosave.flush();
                          final note = await workspace.store.load(
                            widget.noteId,
                          );
                          if (note == null || !context.mounted) return;
                          final paired = await workspace.store.load(
                            pairedRepresentationId(note.id),
                          );
                          if (!context.mounted) return;
                          final export = ExportHandler(
                            note: note,
                            pairedNote: paired,
                            store: workspace.store,
                          );
                          await showExportDialog(context, export);
                          export.dispose();
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
