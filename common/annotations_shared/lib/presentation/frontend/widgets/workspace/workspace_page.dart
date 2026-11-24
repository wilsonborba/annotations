import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/models/local_note.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../handlers/workspace_handler.dart';
import '../landing/landing_blocks.dart' show isPhone;

/// `/v1/write`: the writer workspace of an installed app. Own notes only,
/// no public feed (A2/F1); "Untitled note" until named (D1.1).
class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, this.handler});

  /// Tests give their own; the app makes one from the workspace.
  final WorkspaceHandler? handler;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  WorkspaceHandler? _handler;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handler != null) return;
    final workspace = AppScope.of(context).workspace;
    _handler =
        widget.handler ??
        (workspace == null ? null : WorkspaceHandler(workspace));
    _handler?.load();
  }

  @override
  void dispose() {
    if (widget.handler == null) _handler?.dispose();
    super.dispose();
  }

  void _say(String key) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(context.tr(key))));

  Future<void> _run(Future<bool> Function() action, String doneKey) async {
    try {
      if (await action()) _say(doneKey);
    } catch (_) {
      _say('backupFailed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final handler = _handler;
    if (handler == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final catalog = handler.workspace.catalog;
    return ListenableBuilder(
      listenable: handler,
      builder: (context, _) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isPhone(context) ? 20 : 48,
          vertical: 32,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      context.tr('workspaceTitle'),
                      style: text.headlineMedium,
                    ),
                    track(
                      'workspace.note.new',
                      AppButton.primary(
                        key: const Key('workspace-new'),
                        label: context.tr('newNote'),
                        icon: AppIcons.add,
                        onPressed: () async {
                          final id = await handler.create();
                          if (context.mounted) context.go('/v1/write/$id');
                        },
                      ),
                    ),
                    track(
                      'workspace.backup.restore',
                      AppButton(
                        key: const Key('workspace-restore'),
                        label: context.tr('restoreBackup'),
                        icon: AppIcons.upload,
                        onPressed: () =>
                            _run(handler.restoreBackup, 'backupRestored'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FilterMenu(
                      key: const Key('filter-project'),
                      label: handler.projectId == null
                          ? context.tr('allProjects')
                          : catalog.projects[handler.projectId] ?? '',
                      entries: [
                        (null, context.tr('allProjects')),
                        for (final e in catalog.projects.entries)
                          (e.key, e.value),
                      ],
                      selected: handler.projectId,
                      onSelected: (v) =>
                          handler.filter(project: v, tag: handler.tag),
                    ),
                    _FilterMenu(
                      key: const Key('filter-tag'),
                      label: handler.tag ?? context.tr('allTags'),
                      entries: [
                        (null, context.tr('allTags')),
                        for (final t in catalog.tags) (t, t),
                      ],
                      selected: handler.tag,
                      onSelected: (v) =>
                          handler.filter(project: handler.projectId, tag: v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (handler.error != null)
                  Text(context.tr('error'), key: const Key('workspace-error'))
                else if (handler.notes == null)
                  const Center(child: CircularProgressIndicator())
                else if (handler.notes!.isEmpty)
                  Text(
                    context.tr('workspaceEmpty'),
                    key: const Key('workspace-empty'),
                    style: text.bodyLarge,
                  )
                else
                  for (final note in handler.notes!)
                    _NoteRow(
                      note: note,
                      handler: handler,
                      onExport: () =>
                          _run(() => handler.exportBackup(note), 'backupSaved'),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    super.key,
    required this.label,
    required this.entries,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<(String?, String)> entries;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final (value, name) in entries)
        MenuItemButton(
          key: Key('filter-${value ?? 'all'}'),
          requestFocusOnHover: false,
          trailingIcon: value == selected
              ? const AppIcon(AppIcons.checkmarkCircle, size: 18)
              : null,
          onPressed: () => onSelected(value),
          child: Text(name),
        ),
    ],
    builder: (context, controller, _) => AppButton(
      label: label,
      icon: AppIcons.chevronDown,
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.handler,
    required this.onExport,
  });

  final LocalNote note;
  final WorkspaceHandler handler;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final catalog = handler.workspace.catalog;
    final project = catalog.projects[catalog.projectForNote(note.id)];
    final tags = catalog.tagsForNote(note.id);
    final state = switch (note.syncState) {
      LocalSyncState.local => 'stateLocal',
      LocalSyncState.synced => 'stateSynced',
      LocalSyncState.changed => 'stateChanged',
    };
    final date = note.updatedAt.toLocal().toIso8601String().split('T').first;
    return InkWell(
      key: Key('note-${note.id}'),
      onTap: () => context.go('/v1/write/${note.id}'),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title ?? context.tr('untitledNote'),
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [date, ?project, ...tags.map((t) => '#$t')].join('  '),
                    style: text.bodySmall!.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            Container(
              key: Key('state-${note.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: c.subtle,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Text(context.tr(state), style: text.labelMedium),
            ),
            const SizedBox(width: 8),
            AppMenuButton(
              key: Key('actions-${note.id}'),
              icon: AppIcons.menu,
              label: context.tr('noteActions'),
              entries: [
                AppMenuEntry(
                  key: Key('export-${note.id}'),
                  label: context.tr('exportBackup'),
                  icon: AppIcons.download,
                  onSelected: onExport,
                ),
                AppMenuEntry(
                  key: Key('remove-${note.id}'),
                  label: context.tr('removeFromDevice'),
                  icon: AppIcons.delete,
                  onSelected: () => _confirmRemove(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: context.tr('removeFromDevice'),
        content: Text(context.tr('removeFromDeviceText')),
        actions: [
          AppButton.subtle(
            key: const Key('remove-cancel'),
            label: context.tr('cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton(
            key: const Key('remove-confirm'),
            label: context.tr('remove'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await handler.removeFromDevice(note);
  }
}
