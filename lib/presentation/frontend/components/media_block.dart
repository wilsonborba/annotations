import 'package:annotations/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../domain/models/content.dart';
import '../../../dal/remote/browser/frames.dart';
import 'scope.dart';
import '../handlers/content_handler.dart';

class MediaBlock extends StatefulWidget {
  final Data block;
  const MediaBlock({super.key, required this.block});
  @override
  State<MediaBlock> createState() => _MediaBlockState();
}

class _MediaBlockState extends State<MediaBlock> {
  Future<Data>? metadata;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.block['type'] != 'reports' && widget.block['type'] != 'image') {
      metadata ??= ContentHandler(
        AppScope.of(context).service,
      ).preview(widget.block['url']);
    }
  }

  Future<void> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && ['http', 'https'].contains(uri.scheme)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  IconData provider(String? name) => switch (name) {
    'google-drive' => Icons.add_to_drive_outlined,
    'discord' => Icons.forum_outlined,
    'youtube' => Icons.smart_display_outlined,
    _ => Icons.link_rounded,
  };
  Widget card(Data data) {
    final block = widget.block;
    final url = block['url'].toString();
    final domain = (data['domain'] ?? Uri.tryParse(url)?.host ?? url)
        .toString();
    final title = (block['title'] ?? data['title'] ?? domain).toString();
    final thumbnail = (data['thumbnail'] ?? '').toString();
    final icon = Icon(
      block['type'] == 'pdf'
          ? Icons.picture_as_pdf_outlined
          : provider(data['provider'] as String?),
      size: 28,
      color: Theme.of(context).colorScheme.primary,
    );
    final leading = thumbnail.isEmpty
        ? icon
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.network(
              thumbnail,
              width: 84,
              height: 62,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => icon,
            ),
          );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(6),
      child: track(
        'article.media.link',
        InkWell(
          onTap: () => open(url),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: leading,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Icon(Icons.north_east_rounded, size: 17),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final type = block['type'];
    final url = block['url'].toString();
    if (type == 'image') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(
              url,
              width: double.infinity,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Padding(
                padding: EdgeInsets.all(24),
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          if ((block['caption'] ?? '').toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                block['caption'],
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );
    }
    if (type == 'reports') {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            embeddedFrame(url, height: 480),
            Align(
              alignment: Alignment.centerRight,
              child: track(
                'article.media.report',
                TextButton.icon(
                  onPressed: () =>
                      open((block['source_url'] ?? url).toString()),
                  icon: const Icon(Icons.north_east_rounded, size: 15),
                  label: Text(context.tr('open')),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return FutureBuilder<Data>(
      future: metadata,
      builder: (context, s) {
        final data = s.data ?? <String, dynamic>{};
        final embed = (data['embed_url'] ?? '').toString();
        return Column(
          children: [
            if (type == 'youtube' && embed.isNotEmpty)
              embeddedFrame(embed, height: 420),
            card(data),
          ],
        );
      },
    );
  }
}
