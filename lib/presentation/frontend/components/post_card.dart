import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../domain/models/content.dart';

class PostCard extends StatelessWidget {
  final Data post;
  const PostCard({super.key, required this.post});
  @override
  Widget build(BuildContext context) {
    final topics = labels(post['topics']);
    final channels = labels(post['channels']);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.go(
          '/v1/menu/${channels.firstOrNull ?? 'asodya'}/${post['slug']}?lang=${post['language'] ?? 'en'}',
        ),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((post['cover_url'] ?? '').toString().isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  child: Image.network(
                    post['cover_url'],
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(height: 16),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.article_outlined,
                          size: 17,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            topics.isEmpty
                                ? 'ANNOTATIONS'
                                : topics.join(' / ').toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.2,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        Text(
                          (post['language'] ?? '').toString().toUpperCase(),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      post['title'] ?? '',
                      style: Theme.of(context).textTheme.titleLarge,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      post['summary'] ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ((post['author'] as Map?)?['name'] ?? '')
                                .toString(),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const Icon(Icons.north_east_rounded, size: 18),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PostGrid extends StatelessWidget {
  final List<Data> items;
  const PostGrid({super.key, required this.items});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final columns = c.maxWidth > 950
          ? 3
          : c.maxWidth > 600
          ? 2
          : 1;
      final width = (c.maxWidth - (columns - 1) * 20) / columns;
      return Wrap(
        spacing: 20,
        runSpacing: 20,
        children: items
            .map(
              (post) => SizedBox(
                width: width,
                child: PostCard(post: post),
              ),
            )
            .toList(),
      );
    },
  );
}
