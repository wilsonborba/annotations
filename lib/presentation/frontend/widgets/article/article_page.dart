import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../../domain/models/content.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/body_blocks.dart';
import '../../handlers/content_handler.dart';

class ArticlePage extends StatefulWidget {
  final String channel, slug, language;
  const ArticlePage({
    super.key,
    required this.channel,
    required this.slug,
    required this.language,
  });
  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  Future<Data>? data;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    data ??= load();
  }

  @override
  void didUpdateWidget(ArticlePage old) {
    super.didUpdateWidget(old);
    if (old.slug != widget.slug ||
        old.language != widget.language ||
        old.channel != widget.channel) {
      data = load();
    }
  }

  Future<Data> load() => ContentHandler(
    AppScope.of(context).service,
  ).article(widget.slug, language: widget.language, channel: widget.channel);
  void language(String value) => context.go(
    Uri(
      path: '/v1/menu/${widget.channel}/${widget.slug}',
      queryParameters: {'lang': value},
    ).toString(),
  );
  @override
  Widget build(BuildContext context) => ContentWidth(
    width: 1000,
    child: FutureBuilder<Data>(
      future: data,
      builder: (context, s) {
        if (s.hasError) {
          return LoadError(retry: () => setState(() => data = load()));
        }
        if (!s.hasData) {
          return const Padding(
            padding: EdgeInsets.all(80),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final article = s.data!;
        final available = labels(article['available_languages']);
        return SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: () => context.go('/v1/menu'),
                icon: const Icon(Icons.arrow_back_rounded, size: 17),
                label: Text(context.tr('back')),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: labels(article['topics'])
                    .map(
                      (topic) => Chip(
                        label: Text(topic),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 18),
              Text(
                article['title'] ?? '',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontSize: MediaQuery.sizeOf(context).width > 740 ? 49 : 34,
                ),
              ),
              const SizedBox(height: 18),
              if ((article['summary'] ?? '').toString().isNotEmpty)
                Text(
                  article['summary'],
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 19,
                  ),
                ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 30,
                runSpacing: 12,
                children: [
                  Text(
                    '${article['owner_id']} · ${DateTime.fromMillisecondsSinceEpoch(((article['updated_at'] ?? 0) as num).toInt() * 1000).toIso8601String().split('T').first}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.tr('contentLanguage'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(width: 14),
                      DropdownButton<String>(
                        key: const Key('content-language'),
                        value: article['language'],
                        items: available
                            .map(
                              (code) => DropdownMenuItem(
                                value: code,
                                child: Text(
                                  code == 'pt-BR'
                                      ? 'Português'
                                      : code == 'th'
                                      ? 'ไทย'
                                      : code == 'en'
                                      ? 'English'
                                      : code,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) language(v);
                        },
                      ),
                    ],
                  ),
                  IconButton(
                    tooltip: context.tr('copy'),
                    onPressed: () async {
                      final uri = Uri.base.replace(
                        path: '/v1/menu/${widget.channel}/${widget.slug}',
                        queryParameters: {'lang': article['language']},
                      );
                      await Clipboard.setData(
                        ClipboardData(text: uri.toString()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(context.tr('copied'))),
                        );
                      }
                    },
                    icon: const Icon(Icons.link_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Divider(color: Theme.of(context).dividerColor),
              const SizedBox(height: 26),
              if ((article['cover_url'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.network(
                      article['cover_url'],
                      width: double.infinity,
                      height: 330,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              BodyBlocks(
                body: Map<String, dynamic>.from(article['body'] ?? {}),
              ),
            ],
          ),
        );
      },
    ),
  );
}
