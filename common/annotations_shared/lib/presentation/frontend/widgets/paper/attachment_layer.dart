/// The controls of files and links on paper (annotations#34): the Add menu,
/// the card actions, the copy jobs at their place on the page, and the
/// dialogs to confirm Remove and to type a link.
library;

import 'package:flutter/material.dart';

import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/attachment_handler.dart';
import '../../handlers/paper_handler.dart';

/// Add: a file or picture through the file picker, or a link.
class AddMenu extends StatelessWidget {
  final AttachmentHandler attachments;
  const AddMenu({super.key, required this.attachments});

  @override
  Widget build(BuildContext context) => AppMenuButton(
    key: const Key('add-menu'),
    icon: AppIcons.add,
    label: context.tr('addMenu'),
    entries: [
      AppMenuEntry(
        key: const Key('add-file'),
        label: context.tr('addFile'),
        icon: AppIcons.upload,
        onSelected: () => attachments.pick(),
      ),
      AppMenuEntry(
        key: const Key('add-link'),
        label: context.tr('addLink'),
        icon: AppIcons.link,
        onSelected: () async {
          final url = await askLink(context);
          if (url != null) await attachments.addLink(url);
        },
      ),
    ],
  );
}

/// The actions of the one selected card [id] (B9.3) in one menu, so the
/// toolbar keeps one row: pictures and files Open, Save a copy, Replace and
/// Remove; links Open, Copy link, Edit link and Remove.
class CardMenu extends StatelessWidget {
  final AttachmentHandler attachments;
  final String id;
  const CardMenu({super.key, required this.attachments, required this.id});

  @override
  Widget build(BuildContext context) {
    final link = attachments.isLink(id);
    AppMenuEntry entry(String key, VoidCallback action) => AppMenuEntry(
      key: Key('card-$key'),
      label: context.tr(
        'card${key.split('-').map((w) => w[0].toUpperCase() + w.substring(1)).join()}',
      ),
      onSelected: action,
    );
    return AppMenuButton(
      key: const Key('card-menu'),
      icon: link ? AppIcons.link : AppIcons.file,
      label: context.tr(link ? 'cardLinkMenu' : 'cardFileMenu'),
      entries: [
        entry('open', () => attachments.open(id)),
        if (link) ...[
          entry('copy-link', () => attachments.copyLink(id)),
          entry('edit-link', () async {
            final url = await askLink(context, edit: true);
            if (url != null) await attachments.editLink(id, url);
          }),
        ] else ...[
          entry('save-copy', () => attachments.saveCopy(id)),
          entry('replace', () => attachments.replace(id)),
        ],
        entry('remove', () async {
          if (await confirmRemove(context)) attachments.remove(id);
        }),
      ],
    );
  }
}

/// Asks before a card leaves the note (B9.5).
Future<bool> confirmRemove(BuildContext context) async =>
    await showAppDialog<bool>(
      context,
      (context) => AppDialog(
        key: const Key('remove-dialog'),
        title: context.tr('removeCardTitle'),
        content: Text(context.tr('removeCardBody')),
        actions: [
          AppButton(
            label: context.tr('cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton.primary(
            key: const Key('remove-confirm'),
            label: context.tr('cardRemove'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    ) ??
    false;

/// Asks for a web link; null when the user cancels.
Future<String?> askLink(BuildContext context, {bool edit = false}) =>
    showAppDialog<String>(context, (context) => _LinkDialog(edit: edit));

class _LinkDialog extends StatefulWidget {
  final bool edit;
  const _LinkDialog({required this.edit});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _save() {
    final text = _value.text.trim();
    if (text.isNotEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    key: const Key('link-dialog'),
    title: context.tr(widget.edit ? 'cardEditLink' : 'addLink'),
    content: TextField(
      key: const Key('link-field'),
      controller: _value,
      autofocus: true,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(hintText: context.tr('linkHint')),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      AppButton(
        label: context.tr('cancel'),
        onPressed: () => Navigator.pop(context),
      ),
      AppButton.primary(
        key: const Key('link-save'),
        label: context.tr('save'),
        onPressed: _save,
      ),
    ],
  );
}

/// The copy jobs at the place of their card: the file name while it
/// copies; Retry and Cancel when the copy failed (B9.6).
class AttachmentJobsLayer extends StatelessWidget {
  final AttachmentHandler attachments;
  final PaperView view;
  const AttachmentJobsLayer({
    super.key,
    required this.attachments,
    required this.view,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: attachments.jobs,
    builder: (context, jobs, _) {
      final c = context.colors;
      return Stack(
        children: [
          for (final job in jobs)
            Positioned(
              left: view.toScreen(job.at).dx,
              top: view.toScreen(job.at).dy,
              child: Container(
                key: Key('attachment-job-${job.source.name}'),
                constraints: const BoxConstraints(maxWidth: 360),
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(appPanelRadius),
                  border: Border.all(
                    color: job.state == AttachmentJobState.failed
                        ? c.danger
                        : c.border,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (job.state == AttachmentJobState.copying)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: c.icon,
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        context
                            .tr(
                              job.state == AttachmentJobState.failed
                                  ? 'jobFailed'
                                  : 'jobCopying',
                            )
                            .replaceAll('{name}', job.source.name),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (job.state == AttachmentJobState.failed)
                      AppButton(
                        key: const Key('job-retry'),
                        label: context.tr('retry'),
                        onPressed: () => attachments.retry(job),
                      ),
                    AppButton(
                      key: const Key('job-cancel'),
                      label: context.tr('cancel'),
                      onPressed: () => attachments.cancel(job),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
