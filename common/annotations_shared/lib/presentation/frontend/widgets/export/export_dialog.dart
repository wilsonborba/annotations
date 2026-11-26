import 'package:flutter/material.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/pdf_export_mapper.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../handlers/export_handler.dart';
import '../landing/landing_blocks.dart' show isPhone;

/// Opens the export flow of a note (annotations#42).
Future<void> showExportDialog(BuildContext context, ExportHandler handler) =>
    showDialog<void>(
      context: context,
      builder: (_) => ExportDialog(handler: handler),
    );

/// Representation, paper and orientation, the preflight list, the print
/// preview drawn from the generated PDF(s), and Save.
class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key, required this.handler});

  final ExportHandler handler;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  @override
  void initState() {
    super.initState();
    widget.handler.build();
  }

  String _issue(PdfPreflightIssue issue) => switch (issue.kind) {
    'missing_file' => context.tr('issueMissingFile'),
    'unsupported_content' => context.tr('issueUnsupportedContent'),
    'failed_chart' => context.tr('issueFailedChart'),
    'partial_chart' => context.tr('issuePartialReport'),
    _ => context.tr('issueMissingFont'),
  };

  String _modeLabel(BuildContext context, PdfExportMode mode) => switch (mode) {
    PdfExportMode.original => context.tr('exportOriginal'),
    PdfExportMode.typed => context.tr('exportTyped'),
    PdfExportMode.both => context.tr('exportBoth'),
  };

  @override
  Widget build(BuildContext context) {
    final h = widget.handler;
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    final phone = isPhone(context);
    return Dialog(
      key: const Key('export-dialog'),
      insetPadding: EdgeInsets.all(phone ? 8 : 32),
      child: ListenableBuilder(
        listenable: h,
        builder: (context, _) {
          final pre = h.preflight;
          final zip = h.needsZip;
          final modes = h.modes;
          final previewPdfs = h.previewPdfs;
          final multiPdf = previewPdfs.length > 1;
          var flatIndex = 0;
          return Padding(
            padding: EdgeInsets.all(phone ? 16 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.tr('exportPdf'), style: text.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (modes.length > 1)
                      SegmentedButton<PdfExportMode>(
                        key: const Key('export-mode'),
                        showSelectedIcon: false,
                        segments: [
                          for (final m in modes)
                            ButtonSegment(
                              value: m,
                              label: Text(_modeLabel(context, m)),
                            ),
                        ],
                        selected: {h.mode},
                        onSelectionChanged: (v) => h.choose(mode: v.first),
                      ),
                    SegmentedButton<PdfPaperSize>(
                      key: const Key('export-paper'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: PdfPaperSize.a4,
                          label: Text(context.tr('paperA4')),
                        ),
                        ButtonSegment(
                          value: PdfPaperSize.letter,
                          label: Text(context.tr('paperLetter')),
                        ),
                      ],
                      selected: {h.paper},
                      onSelectionChanged: (v) => h.choose(paper: v.first),
                    ),
                    SegmentedButton<PdfOrientation>(
                      key: const Key('export-orientation'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: PdfOrientation.portrait,
                          label: Text(context.tr('portrait')),
                        ),
                        ButtonSegment(
                          value: PdfOrientation.landscape,
                          label: Text(context.tr('landscape')),
                        ),
                      ],
                      selected: {h.orientation},
                      onSelectionChanged: (v) => h.choose(orientation: v.first),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (pre?.hasPrivateChartWarning ?? false)
                  Container(
                    key: const Key('export-private'),
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: c.subtle,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(context.tr('privateWarning')),
                  ),
                if (h.stage == ExportStage.preflight && pre != null) ...[
                  Text(
                    context.tr('preflightTitle'),
                    key: const Key('export-preflight'),
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: phone ? 132 : 180),
                    child: SingleChildScrollView(
                      key: const Key('export-preflight-list'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final issue in pre.issues)
                            Padding(
                              key: Key('issue-${issue.refId}'),
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                '${_issue(issue)}: ${h.issueTarget(issue)}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      track(
                        'export.retry',
                        AppButton(
                          key: const Key('export-retry'),
                          label: context.tr('retry'),
                          onPressed: () => h.build(placeholders: false),
                        ),
                      ),
                      track(
                        'export.placeholders',
                        AppButton(
                          key: const Key('export-continue'),
                          label: context.tr('continuePlaceholders'),
                          onPressed: () => h.build(placeholders: true),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: h.stage == ExportStage.working
                      ? const Center(child: CircularProgressIndicator())
                      : h.stage == ExportStage.failed
                      ? Center(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppIcon(
                                  AppIcons.cloudDisconnected,
                                  size: 36,
                                  color: c.danger,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  context.tr('exportFailed'),
                                  key: const Key('export-failed'),
                                  style: text.titleMedium,
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                track(
                                  'export.retry',
                                  AppButton(
                                    key: const Key('export-failed-retry'),
                                    label: context.tr('retry'),
                                    onPressed: h.build,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: c.subtle,
                          child: ListView(
                            key: const Key('export-preview'),
                            padding: const EdgeInsets.all(16),
                            children: [
                              for (final group in previewPdfs) ...[
                                if (multiPdf)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      group.filename,
                                      key: Key(
                                        'preview-file-${group.filename}',
                                      ),
                                      style: text.labelLarge,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                for (final page in group.pages)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final naturalWidth = page.width / 1.5;
                                        final availableWidth =
                                            (constraints.maxWidth - 32)
                                                .clamp(
                                                  1.0,
                                                  constraints.maxWidth,
                                                )
                                                .toDouble();
                                        final previewWidth =
                                            naturalWidth > availableWidth
                                            ? availableWidth
                                            : naturalWidth;
                                        return Center(
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                color: c.border,
                                              ),
                                            ),
                                            child: RawImage(
                                              key: Key(
                                                'preview-page-${flatIndex++}',
                                              ),
                                              image: page,
                                              width: previewWidth,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                ),
                if (h.saveError) ...[
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('export-save-error'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: c.subtle,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.danger),
                    ),
                    child: Text(
                      context.tr('exportSaveFailed'),
                      style: text.bodyMedium!.copyWith(color: c.danger),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (h.pages.isNotEmpty)
                      Text(
                        '${h.pages.length} ${context.tr(h.pages.length == 1 ? 'previewPage' : 'previewPages')}',
                        key: const Key('export-count'),
                      ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppButton.subtle(
                          key: const Key('export-close'),
                          label: context.tr('cancel'),
                          onPressed: () => Navigator.pop(context),
                        ),
                        track(
                          'export.save',
                          AppButton.primary(
                            key: const Key('export-save'),
                            label: context.tr(
                              zip ? 'exportSaveZip' : 'exportSavePdf',
                            ),
                            icon: AppIcons.download,
                            onPressed: h.stage == ExportStage.ready
                                ? () async {
                                    final messenger = ScaffoldMessenger.of(
                                      context,
                                    );
                                    final done = context.tr('exportSaved');
                                    final saved = await h.save();
                                    if (!saved || !context.mounted) return;
                                    Navigator.pop(context);
                                    messenger.showSnackBar(
                                      SnackBar(content: Text(done)),
                                    );
                                  }
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
