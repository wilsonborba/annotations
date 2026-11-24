import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';

import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../domain/services/installed_account.dart';
import '../../../../domain/services/note_sync_service.dart';
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
    final scope = AppScope.of(context);
    final workspace = scope.workspace;
    final installed = _installed = scope.installed;
    _handler =
        widget.handler ??
        (workspace == null
            ? null
            : WorkspaceHandler(
                workspace,
                account: installed,
                sync: installed == null
                    ? null
                    : NoteSyncService(
                        store: workspace.store,
                        api: ApiAdapter(
                          client: SessionClient(installed, installed.client),
                        ),
                      ),
              ));
    installed?.addListener(_accountChanged);
    _handler?.load();
  }

  InstalledAccount? _installed;

  void _accountChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _installed?.removeListener(_accountChanged);
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
            if (handler.failed[note.id] case final retry?) ...[
              track(
                'workspace.cloud.retry',
                AppButton(
                  key: Key('retry-${note.id}'),
                  label: context.tr('retry'),
                  onPressed: retry,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Container(
              key: Key('state-${note.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: c.subtle,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Text(
                context.tr(
                  handler.busy.contains(note.id)
                      ? 'stateWorking'
                      : handler.failed.containsKey(note.id)
                      ? 'stateFailed'
                      : state,
                ),
                style: text.labelMedium,
              ),
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
                if (handler.canSync) ...[
                  AppMenuEntry(
                    key: Key('sync-${note.id}'),
                    label: context.tr('syncNow'),
                    icon: AppIcons.cloud,
                    onSelected: () => handler.syncNote(note),
                  ),
                  AppMenuEntry(
                    key: Key('publish-${note.id}'),
                    label: context.tr('publish'),
                    icon: AppIcons.upload,
                    onSelected: () => _publish(context),
                  ),
                  if (handler.published.containsKey(note.id))
                    AppMenuEntry(
                      key: Key('unpublish-${note.id}'),
                      label: context.tr('unpublish'),
                      onSelected: () => handler.unpublish(note),
                    ),
                  if (note.accountId != null)
                    AppMenuEntry(
                      key: Key('delete-everywhere-${note.id}'),
                      label: context.tr('deleteEverywhere'),
                      icon: AppIcons.delete,
                      onSelected: () => _confirmDeleteEverywhere(context),
                    ),
                ] else if (handler.account != null)
                  AppMenuEntry(
                    key: Key('sign-in-to-sync-${note.id}'),
                    label: context.tr('signInToSync'),
                    icon: AppIcons.cloud,
                    onSelected: () => context.go('/v1/sign-in'),
                  ),
                AppMenuEntry(
                  key: Key('project-${note.id}'),
                  label: context.tr('setProject'),
                  icon: AppIcons.fileText,
                  onSelected: () => _project(context),
                ),
                AppMenuEntry(
                  key: Key('tag-${note.id}'),
                  label: context.tr('addTag'),
                  icon: AppIcons.add,
                  onSelected: () => _tag(context),
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

  Future<void> _confirmDeleteEverywhere(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: context.tr('deleteEverywhere'),
        content: Text(context.tr('deleteEverywhereText')),
        actions: [
          AppButton.subtle(
            key: const Key('delete-cancel'),
            label: context.tr('cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton(
            key: const Key('delete-confirm'),
            label: context.tr('delete'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await handler.deleteEverywhere(note);
  }

  /// The publish dialog: the bound account before the first publication
  /// (D1.5), Original, Typed or both, and the restricted embed warning.
  Future<void> _publish(BuildContext context) async {
    final typedOnly = note.schema.name == 'note-typed';
    var choice = typedOnly
        ? PublicationRepresentation.typed
        : PublicationRepresentation.original;
    var allow = false;
    final restricted = handler.restrictedEmbeds(note);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AppDialog(
          title: context.tr('publish'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${context.tr('publishAs')} ${handler.account?.email ?? ''}',
                key: const Key('publish-account'),
              ),
              const SizedBox(height: 16),
              RadioGroup<PublicationRepresentation>(
                groupValue: choice,
                onChanged: (v) => set(() => choice = v!),
                child: Column(
                  children: [
                    for (final (value, label) in [
                      if (!typedOnly)
                        (PublicationRepresentation.original, 'publishOriginal'),
                      (PublicationRepresentation.typed, 'publishTyped'),
                      if (!typedOnly)
                        (PublicationRepresentation.both, 'publishBoth'),
                    ])
                      RadioListTile<PublicationRepresentation>(
                        key: Key('publish-${value.code}'),
                        contentPadding: EdgeInsets.zero,
                        value: value,
                        title: Text(context.tr(label)),
                      ),
                  ],
                ),
              ),
              if (restricted > 0) ...[
                const SizedBox(height: 8),
                Text(
                  context.tr('restrictedWarning'),
                  key: const Key('publish-restricted'),
                ),
                CheckboxListTile(
                  key: const Key('publish-allow'),
                  contentPadding: EdgeInsets.zero,
                  value: allow,
                  title: Text(context.tr('publishAnyway')),
                  onChanged: (v) => set(() => allow = v ?? false),
                ),
              ],
            ],
          ),
          actions: [
            AppButton.subtle(
              key: const Key('publish-cancel'),
              label: context.tr('cancel'),
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton.primary(
              key: const Key('publish-confirm'),
              label: context.tr('publish'),
              onPressed: restricted > 0 && !allow
                  ? null
                  : () => Navigator.pop(context, true),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await handler.publish(note, choice, allowRestricted: allow);
    }
  }

  Future<void> _project(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => _ProjectDialog(handler: handler, note: note),
  );

  Future<void> _tag(BuildContext context) async {
    final tag = await showDialog<String>(
      context: context,
      builder: (_) => const _TagDialog(),
    );
    if (tag != null) handler.addTag(note, tag);
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

/// Chooses a project for a note or creates one; the dialog owns its field.
class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({required this.handler, required this.note});

  final WorkspaceHandler handler;
  final LocalNote note;

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handler = widget.handler;
    final catalog = handler.workspace.catalog;
    return AppDialog(
      title: context.tr('setProject'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in catalog.projects.entries)
            ListTile(
              key: Key('choose-project-${e.key}'),
              contentPadding: EdgeInsets.zero,
              title: Text(e.value),
              selected: catalog.projectForNote(widget.note.id) == e.key,
              onTap: () {
                handler.setProject(widget.note, projectId: e.key);
                Navigator.pop(context);
              },
            ),
          TextField(
            key: const Key('new-project-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: context.tr('newProjectName'),
              errorText: _error,
            ),
          ),
        ],
      ),
      actions: [
        AppButton.subtle(
          label: context.tr('cancel'),
          onPressed: () => Navigator.pop(context),
        ),
        AppButton.primary(
          key: const Key('project-save'),
          label: context.tr('save'),
          onPressed: () {
            if (handler.setProject(widget.note, newName: _name.text)) {
              Navigator.pop(context);
            } else {
              setState(() => _error = context.tr('projectExists'));
            }
          },
        ),
      ],
    );
  }
}

/// Asks for a tag name; the dialog owns its field.
class _TagDialog extends StatefulWidget {
  const _TagDialog();

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: context.tr('addTag'),
    content: TextField(
      key: const Key('tag-name'),
      controller: _name,
      decoration: InputDecoration(labelText: context.tr('tagName')),
    ),
    actions: [
      AppButton.subtle(
        label: context.tr('cancel'),
        onPressed: () => Navigator.pop(context),
      ),
      AppButton.primary(
        key: const Key('tag-save'),
        label: context.tr('save'),
        onPressed: () => Navigator.pop(context, _name.text),
      ),
    ],
  );
}
