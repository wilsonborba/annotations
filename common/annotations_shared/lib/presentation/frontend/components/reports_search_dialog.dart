import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reports_view/reports_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../domain/models/reports_card_reference.dart';
import '../../../domain/models/reports_embed_data.dart';
import '../../../domain/services/reports_embed_source.dart';
import 'scope.dart';

enum _EmbedMode { live, snapshot }

Future<ReportsProjectChoice?> showReportsProjectPicker(
  BuildContext context, {
  required ReportsEmbedSource source,
  required String language,
  bool Function()? isOwnerScopeCurrent,
  ValueListenable<int>? ownerScopeRevision,
  int? expectedOwnerScopeRevision,
}) async {
  if (isOwnerScopeCurrent?.call() == false) return null;
  final projects = await source.allProjects(language: language);
  if (!context.mounted || isOwnerScopeCurrent?.call() == false) return null;
  return showDialog<ReportsProjectChoice>(
    context: context,
    builder: (dialogContext) => _ReportsProjectPickerDialog(
      projects: projects,
      isOwnerScopeCurrent: isOwnerScopeCurrent,
      ownerScopeRevision: ownerScopeRevision,
      expectedOwnerScopeRevision: expectedOwnerScopeRevision,
    ),
  );
}

class _ReportsProjectPickerDialog extends StatefulWidget {
  const _ReportsProjectPickerDialog({
    required this.projects,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });
  final List<ReportsProjectChoice> projects;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_ReportsProjectPickerDialog> createState() =>
      _ReportsProjectPickerDialogState();
}

class _ReportsProjectPickerDialogState
    extends State<_ReportsProjectPickerDialog> {
  @override
  void initState() {
    super.initState();
    widget.ownerScopeRevision?.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (widget.ownerScopeRevision?.value == widget.expectedOwnerScopeRevision &&
        (widget.isOwnerScopeCurrent?.call() ?? true)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    widget.ownerScopeRevision?.removeListener(_scopeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext dialogContext) => AlertDialog(
    title: Text(dialogContext.tr('reportsProjectsTitle')),
    content: SizedBox(
      width: 420,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480),
        child: widget.projects.isEmpty
            ? Text(dialogContext.tr('reportsProjectsEmpty'))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: widget.projects.length,
                itemBuilder: (context, index) {
                  final project = widget.projects[index];
                  return ListTile(
                    key: Key('reports-project-${project.slug}'),
                    title: Text(project.name),
                    onTap: widget.isOwnerScopeCurrent?.call() == false
                        ? null
                        : () => Navigator.of(dialogContext).pop(project),
                  );
                },
              ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(dialogContext.tr('cancel')),
      ),
    ],
  );
}

/// Compact, permission-filtered Reports search for one known project.
/// The caller supplies the saved note destination and owns persistence.
Future<ReportsEmbedReference?> showReportsSearchDialog(
  BuildContext context, {
  required ReportsEmbedSource source,
  required String project,
  required String language,
  bool Function()? isOwnerScopeCurrent,
  ValueListenable<int>? ownerScopeRevision,
  int? expectedOwnerScopeRevision,
}) => showDialog<ReportsEmbedReference>(
  context: context,
  builder: (context) => _ReportsSearchDialog(
    source: source,
    project: project,
    language: language,
    isOwnerScopeCurrent: isOwnerScopeCurrent,
    ownerScopeRevision: ownerScopeRevision,
    expectedOwnerScopeRevision: expectedOwnerScopeRevision,
  ),
);

class _ReportsSearchDialog extends StatefulWidget {
  const _ReportsSearchDialog({
    required this.source,
    required this.project,
    required this.language,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });

  final ReportsEmbedSource source;
  final String project;
  final String language;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_ReportsSearchDialog> createState() => _ReportsSearchDialogState();
}

class _ReportsSearchDialogState extends State<_ReportsSearchDialog> {
  final _query = TextEditingController();
  ReportsSearchPage? _results;
  ReportsSearchItem? _selected;
  ReportView? _view;
  String? _dataset;
  _EmbedMode? _mode;
  bool _loading = false;
  bool _saving = false;
  bool _searched = false;
  Object? _error;
  int _generation = 0;

  bool get _ownerScopeIsCurrent => widget.isOwnerScopeCurrent?.call() ?? true;

  @override
  void initState() {
    super.initState();
    widget.ownerScopeRevision?.addListener(_ownerScopeChanged);
  }

  void _ownerScopeChanged() {
    if (widget.ownerScopeRevision?.value == widget.expectedOwnerScopeRevision &&
        _ownerScopeIsCurrent) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _generation++;
    widget.ownerScopeRevision?.removeListener(_ownerScopeChanged);
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_saving || !_ownerScopeIsCurrent) return;
    final seq = ++_generation;
    setState(() {
      _loading = true;
      _searched = true;
      _error = null;
      _selected = null;
      _view = null;
      _dataset = null;
    });
    try {
      final found = await widget.source.searchReports(
        project: widget.project,
        query: _query.text,
        language: widget.language,
        pageSize: 12,
      );
      if (!mounted || seq != _generation) return;
      if (!_ownerScopeIsCurrent) {
        Navigator.of(context).pop();
        return;
      }
      setState(
        () => _results = ReportsSearchPage(
          items: found.items.where((item) => item.canView).toList(),
          page: found.page,
          pageSize: found.pageSize,
          total: found.total,
          language: found.language,
        ),
      );
    } on Object catch (error) {
      if (mounted && seq == _generation) {
        if (!_ownerScopeIsCurrent) {
          Navigator.of(context).pop();
        } else {
          setState(() => _error = error);
        }
      }
    } finally {
      if (mounted && seq == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _select(ReportsSearchItem item) async {
    if (_saving || !_ownerScopeIsCurrent) return;
    final seq = ++_generation;
    setState(() {
      _loading = true;
      _selected = item;
      _view = null;
      _dataset = null;
      _error = null;
    });
    try {
      final report = await widget.source.reportViewForSearchItem(
        item,
        language: widget.language,
      );
      if (!mounted || seq != _generation) return;
      if (!_ownerScopeIsCurrent) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _view = report;
        if (report.datasets.length == 1) {
          _dataset = report.datasets.single.datasetId;
        }
      });
    } on Object catch (error) {
      if (mounted && seq == _generation) {
        if (!_ownerScopeIsCurrent) {
          Navigator.of(context).pop();
        } else {
          setState(() => _error = error);
        }
      }
    } finally {
      if (mounted && seq == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final item = _selected;
    final dataset = _dataset;
    final mode = _mode;
    if (item == null ||
        dataset == null ||
        mode == null ||
        _saving ||
        !_ownerScopeIsCurrent) {
      return;
    }
    final seq = _generation;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? snapshotId;
      int? capturedAt;
      if (mode == _EmbedMode.snapshot) {
        final reference = ReportsCardReference.fromFields(
          project: item.project,
          report: item.slug,
          dataset: dataset,
        );
        if (reference == null) throw StateError('Invalid Reports reference.');
        final captured = await widget.source.captureSnapshot(
          reference: reference,
          reportId: item.slug,
          source: 'link',
          language: widget.language,
        );
        snapshotId = captured.snapshotId;
        capturedAt = captured.capturedAt;
      }
      final created = ReportsEmbedReference(
        reportId: item.slug,
        projectSlug: item.project,
        reportSlug: item.slug,
        datasetId: dataset,
        mode: mode == _EmbedMode.snapshot ? 'snapshot' : 'live',
        source: 'link',
        snapshotId: snapshotId,
        capturedAt: capturedAt,
      );
      if (!mounted ||
          seq != _generation ||
          !_ownerScopeIsCurrent ||
          _selected != item ||
          _dataset != dataset ||
          _mode != mode) {
        if (mounted && !_ownerScopeIsCurrent) Navigator.of(context).pop();
        return;
      }
      Navigator.of(context).pop(created);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tr;
    return AlertDialog(
      title: Text(t('reportsSearchTitle')),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('reports-search-query'),
                      controller: _query,
                      onSubmitted: (_) => _search(),
                      enabled: !_saving,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        labelText: t('reportsSearchLabel'),
                        isDense: true,
                        suffixIcon: IconButton(
                          key: const Key('reports-search-submit'),
                          tooltip: t('reportsSearchAction'),
                          onPressed: _loading || _saving ? null : _search,
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    t('reportsSearchError'),
                    key: const Key('reports-search-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (!_loading && _searched && _results?.items.isEmpty == true)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(t('reportsSearchEmpty')),
                ),
              if (!_loading && _selected == null)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in _results?.items ?? const [])
                        _result(context, item),
                    ],
                  ),
                ),
              if (_selected != null && !_loading) _datasetPicker(context),
              if (_selected != null && _view != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        key: const Key('reports-mode-live'),
                        label: Text(t('reportsLive')),
                        selected: _mode == _EmbedMode.live,
                        onSelected: _saving
                            ? null
                            : (selected) => setState(
                                () => _mode = selected ? _EmbedMode.live : null,
                              ),
                      ),
                      ChoiceChip(
                        key: const Key('reports-mode-snapshot'),
                        label: Text(t('reportsSnapshot')),
                        selected: _mode == _EmbedMode.snapshot,
                        onSelected: _saving
                            ? null
                            : (selected) => setState(
                                () => _mode = selected
                                    ? _EmbedMode.snapshot
                                    : null,
                              ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(t('cancel')),
        ),
        FilledButton(
          key: const Key('reports-add-embed'),
          onPressed: _saving || _dataset == null || _mode == null ? null : _add,
          child: Text(_saving ? t('reportsSaving') : t('reportsAdd')),
        ),
      ],
    );
  }

  Widget _result(BuildContext context, ReportsSearchItem item) => ListTile(
    key: Key('reports-search-result-${item.slug}'),
    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      '${item.chartTypes.join(', ')} · ${_audienceLabel(context, item.audience)}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: context.tr('reportsOpen'),
      icon: const Icon(Icons.open_in_new),
      onPressed: _saving
          ? null
          : () => launchUrl(Uri.parse(item.openInReportsUrl)),
    ),
    onTap: _saving ? null : () => _select(item),
  );

  Widget _datasetPicker(BuildContext context) {
    final report = _view;
    if (report == null || report.datasets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(context.tr('reportsNoDatasets')),
      );
    }
    return Flexible(
      child: IgnorePointer(
        ignoring: _saving,
        child: RadioGroup<String>(
          groupValue: _dataset,
          onChanged: (value) => setState(() => _dataset = value),
          child: ListView(
            shrinkWrap: true,
            children: [
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                        _selected = null;
                        _view = null;
                        _dataset = null;
                        _mode = null;
                      }),
                icon: const Icon(Icons.arrow_back),
                label: Text(context.tr('reportsSearchBack')),
              ),
              for (final dataset in report.datasets)
                ListTile(
                  key: Key('reports-dataset-${dataset.datasetId}'),
                  selected: _dataset == dataset.datasetId,
                  leading: Icon(
                    _dataset == dataset.datasetId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(dataset.title),
                  dense: true,
                  onTap: _saving
                      ? null
                      : () => setState(() => _dataset = dataset.datasetId),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _audienceLabel(BuildContext context, String audience) =>
      switch (audience) {
        'public' => context.tr('reportsAudiencePublic'),
        'asodya' || 'signed_in' => context.tr('reportsAudienceSignedIn'),
        'personal' => context.tr('reportsAudiencePersonal'),
        _ => context.tr('reportsAudienceRestricted'),
      };
}
