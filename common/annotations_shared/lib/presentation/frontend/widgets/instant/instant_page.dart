import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import '../../components/icons.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../dal/remote/browser/transfers.dart' as browser;
import '../../../../domain/models/content.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../components/shell.dart';
import '../../handlers/room_handler.dart';

class InstantPage extends StatefulWidget {
  final String? code;
  const InstantPage({super.key, this.code});
  @override
  State<InstantPage> createState() => _InstantPageState();
}

class _InstantPageState extends State<InstantPage> {
  final code = TextEditingController(), text = TextEditingController();
  RoomHandler? handler;
  void Function()? stopPaste;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.code != null && handler == null) start();
  }

  @override
  void didUpdateWidget(InstantPage old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code) {
      handler?.dispose();
      stopPaste?.call();
      handler = null;
      if (widget.code != null) start();
    }
  }

  void start() {
    handler = RoomHandler(AppScope.of(context).service, widget.code!)..open();
    stopPaste = browser.listenForPaste((file) => handler?.upload(file));
  }

  @override
  void dispose() {
    handler?.dispose();
    stopPaste?.call();
    code.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> editItem(Data item) async {
    final value = TextEditingController(text: item['text']);
    final result = await showAppDialog<String>(
      context,
      (context) => AppDialog(
        title: context.tr('edit'),
        content: SizedBox(
          width: 440,
          child: track(
            'instant.edit.content',
            TextField(controller: value, maxLines: 6),
            controller: value,
          ),
        ),
        actions: [
          track(
            'instant.edit.cancel',
            AppButton(
              label: context.tr('cancel'),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          track(
            'instant.edit.save',
            AppButton.primary(
              label: context.tr('save'),
              onPressed: () {
                trackSubmit(context, 'instant.edit.save');
                Navigator.pop(context, value.text);
              },
            ),
          ),
        ],
      ),
    );
    if (result != null) await handler?.edit(result, id: item['id']);
    value.dispose();
  }

  void openCode(String value) {
    trackSubmit(context, 'instant.room.open');
    if (value.trim().isNotEmpty) {
      context.go('/v1/instant/${Uri.encodeComponent(value.trim())}');
    }
  }

  Future<void> open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Widget removeButton(RoomHandler h, Data item) => track(
    'instant.item.remove',
    AppIconButton(
      key: Key('remove-${item['id']}'),
      icon: AppIcons.delete,
      label: context.tr('remove'),
      iconSize: 18,
      onPressed: h.busy ? null : () => h.remove(item['id']),
    ),
  );

  /// Open writing sheet: a plain page with the actions underneath.
  Widget paper(RoomHandler h) {
    final theme = Theme.of(context);
    final margin = MediaQuery.sizeOf(context).width > 740 ? 48.0 : 22.0;
    return Container(
      key: const Key('room-sheet'),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(margin, 36, margin, 28),
            child: track(
              'instant.composer.text',
              TextField(
                key: const Key('room-text'),
                controller: text,
                minLines: 9,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 17,
                  height: 1.65,
                ),
                decoration: InputDecoration(
                  hintText: context.tr('textLink'),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isCollapsed: true,
                ),
              ),
              controller: text,
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: margin, vertical: 14),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                track(
                  'instant.composer.add',
                  AppButton.primary(
                    label: context.tr('add'),
                    icon: AppIcons.add,
                    onPressed: h.busy
                        ? null
                        : () async {
                            trackSubmit(context, 'instant.composer.add');
                            if (await h.edit(text.text)) text.clear();
                          },
                  ),
                ),
                track(
                  'instant.composer.upload',
                  AppButton(
                    label: context.tr('upload'),
                    icon: AppIcons.upload,
                    onPressed: h.uploadName != null ? null : h.choose,
                  ),
                ),
                Text(context.tr('drop'), style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget roomView(RoomHandler h) {
    if (h.opening) {
      return const Padding(
        padding: EdgeInsets.all(70),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (h.expired) {
      return Column(
        children: [
          AppIcon(
            AppIcons.clock,
            size: 35,
            color: context.colors.iconSecondary,
          ),
          const SizedBox(height: 16),
          Text(context.tr('expired')),
          const SizedBox(height: 18),
          track(
            'instant.room.reopen',
            AppButton(
              label: context.tr('openRoom'),
              onPressed: () => context.go('/v1/instant'),
            ),
          ),
        ],
      );
    }
    if (h.room == null) {
      return LoadError(reference: h.reference, retry: h.open);
    }
    final seconds =
        (((h.room!['expires_at'] as num).toInt() * 1000 -
                    DateTime.now().millisecondsSinceEpoch) /
                1000)
            .ceil()
            .clamp(0, 900);
    final items = records(h.room!['items']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 10,
            spacing: 20,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(AppIcons.peopleGroup, color: context.colors.icon),
                  const SizedBox(width: 12),
                  Text(
                    widget.code!,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 19,
                    ),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(AppIcons.clock, size: 17),
                  const SizedBox(width: 8),
                  Text(
                    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                  ),
                  const SizedBox(width: 20),
                  track(
                    'instant.room.copy',
                    AppButton(
                      label: context.tr('copy'),
                      icon: AppIcons.link,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: Uri.base
                                .replace(
                                  path: '/v1/instant/${widget.code}',
                                  query: '',
                                )
                                .toString(),
                          ),
                        );
                        if (mounted) {
                          showAppToast(context, context.tr('copied'));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          context.tr('roomNote'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 28),
        paper(h),
        const SizedBox(height: 10),
        Text(context.tr('limit'), style: Theme.of(context).textTheme.bodySmall),
        if (h.uploadName != null)
          Container(
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(h.uploadName!),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: h.progress),
                const SizedBox(height: 8),
                Text(
                  h.progress >= 1
                      ? context.tr('processing')
                      : '${context.tr('uploading')} ${(h.progress * 100).round()}%',
                ),
              ],
            ),
          ),
        if (h.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                AppIcon(AppIcons.alertDiamond, color: context.colors.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(h.error!)),
              ],
            ),
          ),
        const SizedBox(height: 28),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 45),
            child: Center(child: Text(context.tr('roomEmpty'))),
          ),
        ...items.map(
          (item) => Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (item['kind'] == 'image')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Image.network(
                      h.fileUrl(item),
                      height: 250,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const AppIcon(AppIcons.image),
                    ),
                  ),
                if (item['kind'] == 'text')
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          item['text'],
                          semanticsLabel: item['text'],
                        ),
                      ),
                      track(
                        'instant.item.edit',
                        AppIconButton(
                          icon: AppIcons.edit,
                          label: context.tr('edit'),
                          iconSize: 18,
                          onPressed: () => editItem(item),
                        ),
                      ),
                      removeButton(h, item),
                    ],
                  ),
                if (item['kind'] == 'link')
                  Row(
                    children: [
                      const AppIcon(AppIcons.link, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: track(
                          'instant.item.link',
                          InkWell(
                            onTap: () => open(item['text']),
                            child: Text(
                              item['text'],
                              style: TextStyle(color: context.colors.link),
                            ),
                          ),
                        ),
                      ),
                      track(
                        'instant.item.edit',
                        AppIconButton(
                          icon: AppIcons.edit,
                          label: context.tr('edit'),
                          iconSize: 18,
                          onPressed: () => editItem(item),
                        ),
                      ),
                      removeButton(h, item),
                    ],
                  ),
                if (item['kind'] == 'file' || item['kind'] == 'image')
                  Row(
                    children: [
                      const AppIcon(AppIcons.file),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${item['filename']} · ${((item['size_bytes'] as num) / 1000000).toStringAsFixed(2)} MB',
                        ),
                      ),
                      track(
                        'instant.item.download',
                        AppIconButton(
                          icon: AppIcons.download,
                          label: context.tr('download'),
                          onPressed: () => open(h.fileUrl(item)),
                        ),
                      ),
                      removeButton(h, item),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ContentWidth(
    width: 980,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ANNOTATIONS',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.7,
            fontWeight: FontWeight.w700,
            color: context.colors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.tr('roomTitle'),
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 18),
        Text(
          context.tr('roomLead'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 35),
        if (handler == null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              track(
                'instant.room.code',
                TextField(
                  controller: code,
                  decoration: InputDecoration(
                    labelText: context.tr('roomCode'),
                  ),
                  onSubmitted: openCode,
                ),
                controller: code,
                sensitive: true,
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: track(
                  'instant.room.open',
                  AppButton.primary(
                    label: context.tr('openRoom'),
                    onPressed: () => openCode(code.text),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(context.tr('roomNote')),
            ],
          )
        else
          AnimatedBuilder(
            animation: handler!,
            builder: (_, _) => roomView(handler!),
          ),
      ],
    ),
  );
}
