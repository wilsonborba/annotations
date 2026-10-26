import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
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
                    '${(article['author'] as Map?)?['name'] ?? ''} · ${DateTime.fromMillisecondsSinceEpoch(((article['updated_at'] ?? 0) as num).toInt() * 1000).toIso8601String().split('T').first}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  ContentLanguageSelector(
                    key: const Key('content-language'),
                    languages: available,
                    selected: article['language'],
                    onChanged: language,
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
              if (article['author'] is Map)
                AboutAuthor(
                  author: Map<String, dynamic>.from(article['author']),
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Language of the article body; independent from the interface language.
/// A dropdown, because an article can offer any number of translations.
class ContentLanguageSelector extends StatelessWidget {
  final List<String> languages;
  final String? selected;
  final ValueChanged<String> onChanged;
  const ContentLanguageSelector({
    super.key,
    required this.languages,
    required this.selected,
    required this.onChanged,
  });
  static String label(String code) => switch (code) {
    'en' => 'English',
    'pt-BR' => 'Português',
    'th' => 'ไทย',
    _ => code,
  };
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.translate_rounded,
            size: 17,
            color: scheme.onSurface.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 8),
          Text(
            context.tr('contentLanguage'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 22, color: theme.dividerColor),
          const SizedBox(width: 4),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              key: const Key('content-language-dropdown'),
              value: languages.contains(selected) ? selected : null,
              borderRadius: BorderRadius.circular(8),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              icon: const Icon(Icons.expand_more_rounded, size: 20),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              items: [
                for (final code in languages)
                  DropdownMenuItem(value: code, child: Text(label(code))),
              ],
              onChanged: (code) {
                if (code != null && code != selected) onChanged(code);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The article's single author, linked to the author's own site.
class AboutAuthor extends StatelessWidget {
  final Map<String, dynamic> author;
  const AboutAuthor({super.key, required this.author});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = (author['url'] ?? '').toString();
    final name = Text(
      (author['name'] ?? '').toString(),
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: url.isEmpty ? null : theme.colorScheme.primary,
      ),
    );
    return Container(
      key: const Key('about-author'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 48),
      padding: const EdgeInsets.only(top: 28),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('aboutAuthor').toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.4),
          ),
          const SizedBox(height: 10),
          if (url.isEmpty)
            name
          else
            InkWell(
              key: const Key('author-link'),
              onTap: () => launchUrl(Uri.parse(url)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  name,
                  const SizedBox(width: 6),
                  Icon(
                    Icons.north_east_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          if (url.isNotEmpty)
            Text(Uri.parse(url).host, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
