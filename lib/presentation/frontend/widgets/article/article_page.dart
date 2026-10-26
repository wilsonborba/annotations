import 'package:flutter/material.dart';

class ArticlePage extends StatelessWidget {
  final String channel, slug, language;
  const ArticlePage({
    super.key,
    required this.channel,
    required this.slug,
    required this.language,
  });
  @override
  Widget build(BuildContext context) => const SizedBox(height: 400);
}
