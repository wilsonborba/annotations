import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/models/reports_embed_data.dart';
import '../../../domain/services/reports_chart_data.dart';
import '../../../domain/services/reports_embed_source.dart';
import 'scope.dart';

typedef NoteReportsChartCreator =
    Future<ReportsEmbedReference> Function({
      required Map<String, Object?> item,
      required String operationKey,
    });

Future<ReportsEmbedReference?> showReportsCreateDialog(
  BuildContext context, {
  required String projectName,
  required List<ReportsTemplateChoice> templates,
  required List<ReportsChartSourceTable> tables,
  required NoteReportsChartCreator create,
  bool Function()? isOwnerScopeCurrent,
  ValueListenable<int>? ownerScopeRevision,
  int? expectedOwnerScopeRevision,
}) {
  if (isOwnerScopeCurrent?.call() == false) {
    return Future.value(null);
  }
  final supported = templates.where(_supportsSingleColumnSlots).toList();
  return showDialog<ReportsEmbedReference>(
    context: context,
    builder: (dialogContext) => _ReportsCreateDialog(
      projectName: projectName,
      templates: supported,
      tables: tables,
      create: create,
      isOwnerScopeCurrent: isOwnerScopeCurrent,
      ownerScopeRevision: ownerScopeRevision,
      expectedOwnerScopeRevision: expectedOwnerScopeRevision,
    ),
  );
}

bool _supportsSingleColumnSlots(ReportsTemplateChoice template) {
  for (final slot in template.slots) {
    final min = slot['min_count'];
    final max = slot['max_count'];
    if (min is! int || max is! int || min > 1 || max < 1) return false;
  }
  return template.kind == 'chart';
}

class _ReportsCreateDialog extends StatefulWidget {
  const _ReportsCreateDialog({
    required this.projectName,
    required this.templates,
    required this.tables,
    required this.create,
    required this.isOwnerScopeCurrent,
    required this.ownerScopeRevision,
    required this.expectedOwnerScopeRevision,
  });

  final String projectName;
  final List<ReportsTemplateChoice> templates;
  final List<ReportsChartSourceTable> tables;
  final NoteReportsChartCreator create;
  final bool Function()? isOwnerScopeCurrent;
  final ValueListenable<int>? ownerScopeRevision;
  final int? expectedOwnerScopeRevision;

  @override
  State<_ReportsCreateDialog> createState() => _ReportsCreateDialogState();
}

class _ReportsCreateDialogState extends State<_ReportsCreateDialog> {
  final _title = TextEditingController();
  final _optionValues = <String, TextEditingController>{};
  final _mapping = <String, String>{};
  late final String _operationKey = _newOperationKey();
  String? _templateSelectionId;
  String? _tableId;
  String? _error;
  bool _saving = false;

  static String _newOperationKey() {
    final random = math.Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  ReportsTemplateChoice? get _template {
    for (final candidate in widget.templates) {
      if (candidate.selectionId == _templateSelectionId) return candidate;
    }
    return widget.templates.firstOrNull;
  }

  ReportsChartSourceTable? get _table {
    for (final candidate in widget.tables) {
      if (candidate.selectionId == _tableId) return candidate;
    }
    return widget.tables.firstOrNull;
  }

  bool get _scopeCurrent => widget.isOwnerScopeCurrent?.call() ?? true;

  @override
  void initState() {
    super.initState();
    _templateSelectionId = widget.templates.firstOrNull?.selectionId;
    _tableId = widget.tables.firstOrNull?.selectionId;
    widget.ownerScopeRevision?.addListener(_scopeChanged);
    _syncTemplateDefaults();
  }

  void _scopeChanged() {
    if (widget.ownerScopeRevision?.value == widget.expectedOwnerScopeRevision &&
        _scopeCurrent) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _syncTemplateDefaults() {
    final template = _template;
    if (template == null) return;
    if (_title.text.trim().isEmpty) _title.text = template.title;
    _mapping.clear();
    for (final option in template.options) {
      final name = option['option_name'];
      final defaultValue = option['default_value'];
      if (name is String && defaultValue is String) {
        final allowed = option['allowed_values'];
        final values = allowed is List
            ? allowed.whereType<String>().toList(growable: false)
            : const <String>[];
        final selectedDefault =
            values.isNotEmpty && !values.contains(defaultValue)
            ? values.first
            : defaultValue;
        _optionValues.putIfAbsent(name, () => TextEditingController());
        _optionValues[name]!.text = selectedDefault;
      }
    }
  }

  bool _slotAccepts(
    Map<String, dynamic> slot,
    ReportsChartSourceColumn column,
  ) {
    final accepted = slot['accepted_types'];
    if (accepted is! List || accepted.isEmpty) return true;
    final types = accepted.whereType<String>().toSet();
    if (column.type == 'integer' || column.type == 'float') {
      return types.contains('integer') || types.contains('float');
    }
    return types.contains(column.type);
  }

  bool get _canSubmit {
    final template = _template;
    final table = _table;
    if (_saving || !_scopeCurrent || template == null || table == null) {
      return false;
    }
    if (_title.text.trim().isEmpty || _mapping.isEmpty) return false;
    for (final slot in template.slots) {
      if (slot['is_required'] == true &&
          !_mapping.containsKey(slot['slot_name'])) {
        return false;
      }
    }
    for (final option in template.options) {
      final name = option['option_name'];
      final kind = option['value_type'];
      final value = name is String ? _optionValues[name]?.text.trim() : null;
      if (value == null) continue;
      if (kind == 'int' && int.tryParse(value) == null) return false;
      if (kind == 'float') {
        final parsed = double.tryParse(value);
        if (parsed == null || !parsed.isFinite) return false;
      }
      if (kind == 'bool' && value != 'true' && value != 'false') return false;
      final allowed = option['allowed_values'];
      if (allowed is List && allowed.isNotEmpty && !allowed.contains(value)) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> _configFor(ReportsTemplateChoice template) {
    final config = <String, Object?>{};
    for (final option in template.options) {
      final name = option['option_name'];
      final kind = option['value_type'];
      if (name is! String || kind is! String) continue;
      final raw = _optionValues[name]?.text.trim();
      if (raw == null) continue;
      config[name] = switch (kind) {
        'bool' => raw == 'true',
        'int' => int.parse(raw),
        'float' => double.parse(raw),
        _ => raw,
      };
    }
    return config;
  }

  Future<void> _submit() async {
    final template = _template;
    final table = _table;
    if (!_canSubmit || template == null || table == null) return;
    final mapping = Map<String, String>.from(_mapping);
    final rows = table.rows;
    final item = <String, Object?>{
      'title': _title.text.trim(),
      'source_app': 'annotations',
      'template_id': template.templateId,
      'template_version': template.version,
      'audience': 'personal',
      'mapping': mapping,
      'config': _configFor(template),
      'rows': rows,
    };
    try {
      validateReportsChartPayload(mapping: mapping, rows: rows);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final reference = await widget.create(
        item: item,
        operationKey: _operationKey,
      );
      if (!mounted) return;
      if (!_scopeCurrent) {
        Navigator.of(context).pop();
        return;
      }
      Navigator.of(context).pop(reference);
    } on Object {
      if (mounted && _scopeCurrent) {
        setState(() => _error = context.tr('reportsCreateFailed'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    widget.ownerScopeRevision?.removeListener(_scopeChanged);
    _title.dispose();
    for (final controller in _optionValues.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final template = _template;
    final table = _table;
    return AlertDialog(
      title: Text(context.tr('reportsCreateTitle')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('reportsCreatePersonalNotice')),
              const SizedBox(height: 6),
              Text(
                '${context.tr('reportsProjectsTitle')}: ${widget.projectName}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('reports-create-title'),
                controller: _title,
                enabled: !_saving,
                decoration: InputDecoration(labelText: context.tr('title')),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('reports-create-table'),
                initialValue: table?.selectionId,
                decoration: InputDecoration(
                  labelText: context.tr('reportsCreateSourceTable'),
                ),
                items: [
                  for (final candidate in widget.tables)
                    DropdownMenuItem(
                      value: candidate.selectionId,
                      child: Text(
                        '${candidate.name} · ${candidate.rows.length}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _tableId = value;
                        _mapping.clear();
                      }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('reports-create-template'),
                initialValue: template?.selectionId,
                decoration: InputDecoration(
                  labelText: context.tr('reportsCreateTemplate'),
                ),
                items: [
                  for (final candidate in widget.templates)
                    DropdownMenuItem(
                      value: candidate.selectionId,
                      child: Text(
                        candidate.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        final oldTemplate = _template;
                        final wasTemplateDefault =
                            _title.text.trim().isEmpty ||
                            _title.text.trim() == oldTemplate?.title.trim();
                        _templateSelectionId = value;
                        _mapping.clear();
                        final newTemplate = _template;
                        if (wasTemplateDefault && newTemplate != null) {
                          _title.text = newTemplate.title;
                        }
                        _syncTemplateDefaults();
                      }),
              ),
              if (template != null && table != null) ...[
                const SizedBox(height: 12),
                for (final slot in template.slots)
                  _slotPicker(context, slot, table),
                for (final option in template.options)
                  _optionControl(context, option),
              ],
              if (widget.templates.isEmpty || widget.tables.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(context.tr('reportsCreateUnavailable')),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    key: const Key('reports-create-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(context.tr('cancel')),
        ),
        FilledButton(
          key: const Key('reports-create-submit'),
          onPressed:
              widget.templates.isEmpty || widget.tables.isEmpty || !_canSubmit
              ? null
              : _submit,
          child: Text(
            _saving
                ? context.tr('reportsSaving')
                : context.tr('reportsCreateAction'),
          ),
        ),
      ],
    );
  }

  Widget _slotPicker(
    BuildContext context,
    Map<String, dynamic> slot,
    ReportsChartSourceTable table,
  ) {
    final name = slot['slot_name'] as String;
    final role = slot['role'] as String? ?? name;
    final required = slot['is_required'] == true;
    final candidates = table.columns
        .where((column) => _slotAccepts(slot, column))
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<String>(
        key: Key(
          'reports-create-slot-$_templateSelectionId-${table.selectionId}-$name',
        ),
        initialValue: _mapping[name] ?? (required ? null : ''),
        decoration: InputDecoration(
          labelText: '${_humanize(role)}${required ? ' *' : ''}',
        ),
        items: [
          if (!required)
            DropdownMenuItem(
              value: '',
              child: Text(context.tr('reportsCreateOptional')),
            ),
          for (final column in candidates)
            DropdownMenuItem(
              value: column.name,
              child: Text(column.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _saving
            ? null
            : (value) => setState(() {
                if (value == null || value.isEmpty) {
                  _mapping.remove(name);
                } else {
                  _mapping[name] = value;
                }
              }),
      ),
    );
  }

  Widget _optionControl(BuildContext context, Map<String, dynamic> option) {
    final name = option['option_name'] as String;
    final type = option['value_type'] as String? ?? 'text';
    final allowed = option['allowed_values'];
    final values = allowed is List
        ? allowed.whereType<String>().toList(growable: false)
        : const <String>[];
    final controller = _optionValues.putIfAbsent(
      name,
      () =>
          TextEditingController(text: option['default_value'] as String? ?? ''),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: values.isNotEmpty
          ? DropdownButtonFormField<String>(
              key: Key('reports-create-option-$_templateSelectionId-$name'),
              initialValue: values.contains(controller.text)
                  ? controller.text
                  : values.first,
              decoration: InputDecoration(labelText: _humanize(name)),
              items: [
                for (final value in values)
                  DropdownMenuItem(value: value, child: Text(_humanize(value))),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      if (value != null) controller.text = value;
                    }),
            )
          : TextField(
              key: Key('reports-create-option-$name'),
              controller: controller,
              enabled: !_saving,
              keyboardType: type == 'int' || type == 'float'
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              decoration: InputDecoration(labelText: _humanize(name)),
              onChanged: (_) => setState(() {}),
            ),
    );
  }

  String _humanize(String value) => value
      .split(RegExp(r'[_\s-]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}
