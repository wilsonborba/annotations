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

/// Paper and orientation, the preflight list, the print preview drawn from
/// the generated PDF, and Save.
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
    'failed_chart' => context.tr('issueFailedChart'),
    _ => context.tr('issueMissingFont'),
  };

  @override
  Widget build(BuildContext context) {
    final h = widget.handler;
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return Dialog(
      key: const Key('export-dialog'),
      insetPadding: EdgeInsets.all(isPhone(context) ? 8 : 32),
      child: ListenableBuilder(
        listenable: h,
        builder: (context, _) {
          final pre = h.preflight;
          final zip = h.output?.companions.isNotEmpty ?? false;
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.tr('exportPdf'), style: text.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
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
                  for (final issue in pre.issues)
                    Padding(
                      key: Key('issue-${issue.refId}'),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('${_issue(issue)}: ${issue.refId}'),
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
                          onPressed: h.build,
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
                if (h.stage == ExportStage.failed)
                  Text(
                    context.tr('exportFailed'),
                    key: const Key('export-failed'),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: h.stage == ExportStage.working
                      ? const Center(child: CircularProgressIndicator())
                      : ColoredBox(
                          color: c.subtle,
                          child: ListView(
                            key: const Key('export-preview'),
                            padding: const EdgeInsets.all(16),
                            children: [
                              for (final (i, page) in h.pages.indexed)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        border: Border.all(color: c.border),
                                      ),
                                      child: RawImage(
                                        key: Key('preview-page-$i'),
                                        image: page,
                                        width: page.width / 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (h.pages.isNotEmpty)
                      Text(
                        '${h.pages.length} ${context.tr('previewPages')}',
                        key: const Key('export-count'),
                      ),
                    const Spacer(),
                    AppButton.subtle(
                      key: const Key('export-close'),
                      label: context.tr('cancel'),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
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
                                final messenger = ScaffoldMessenger.of(context);
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
          );
        },
      ),
    );
  }
}
