import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../dal/remote/browser/transfers.dart' as browser;
import '../../../../domain/models/content.dart';
import '../../components/scope.dart';
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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('edit')),
        content: SizedBox(
          width: 440,
          child: TextField(controller: value, maxLines: 6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value.text),
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
    if (result != null) await handler?.edit(result, id: item['id']);
    value.dispose();
  }

  void openCode(String value) {
    if (value.trim().isNotEmpty) {
      context.go('/v1/instant/${Uri.encodeComponent(value.trim())}');
    }
  }

  Future<void> open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
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
          const Icon(Icons.timer_off_outlined, size: 35),
          const SizedBox(height: 16),
          Text(context.tr('expired')),
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: () => context.go('/v1/instant'),
            child: Text(context.tr('openRoom')),
          ),
        ],
      );
    }
    if (h.room == null) return LoadError(retry: h.open);
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
                  Icon(
                    Icons.meeting_room_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
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
                  const Icon(Icons.schedule_rounded, size: 17),
                  const SizedBox(width: 8),
                  Text(
                    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                  ),
                  const SizedBox(width: 20),
                  OutlinedButton.icon(
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(context.tr('copied'))),
                        );
                      }
                    },
                    icon: const Icon(Icons.link_rounded, size: 16),
                    label: Text(context.tr('copy')),
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
        TextField(
          key: const Key('room-text'),
          controller: text,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(hintText: context.tr('textLink')),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: h.busy
                  ? null
                  : () async {
                      if (await h.edit(text.text)) text.clear();
                    },
              icon: const Icon(Icons.add_rounded),
              label: Text(context.tr('add')),
            ),
            OutlinedButton.icon(
              onPressed: h.uploadName != null ? null : h.choose,
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(context.tr('upload')),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(context.tr('drop'), style: Theme.of(context).textTheme.bodySmall),
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
            child: Text(
              h.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                if (item['kind'] == 'text')
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: SelectableText(item['text'], semanticsLabel: item['text'])),
                      IconButton(
                        onPressed: () => editItem(item),
                        tooltip: context.tr('edit'),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    ],
                  ),
                if (item['kind'] == 'link')
                  Row(
                    children: [
                      const Icon(Icons.link_rounded, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: () => open(item['text']),
                          child: Text(
                            item['text'],
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => editItem(item),
                        tooltip: context.tr('edit'),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    ],
                  ),
                if (item['kind'] == 'file' || item['kind'] == 'image')
                  Row(
                    children: [
                      const Icon(Icons.insert_drive_file_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${item['filename']} · ${((item['size_bytes'] as num) / 1000000).toStringAsFixed(2)} MB',
                        ),
                      ),
                      IconButton(
                        onPressed: () => open(h.fileUrl(item)),
                        tooltip: context.tr('download'),
                        icon: const Icon(Icons.download_rounded),
                      ),
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
          'ASODYA / INSTANT',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.7,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
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
              TextField(
                controller: code,
                decoration: InputDecoration(labelText: context.tr('roomCode')),
                onSubmitted: openCode,
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: () => openCode(code.text),
                  child: Text(context.tr('openRoom')),
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
