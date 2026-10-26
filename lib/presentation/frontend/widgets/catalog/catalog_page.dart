import 'package:flutter/material.dart';

class CatalogPage extends StatelessWidget {
  final String query, topic, channel;
  const CatalogPage({
    super.key,
    this.query = '',
    this.topic = '',
    this.channel = '',
  });
  @override
  Widget build(BuildContext context) => const SizedBox(height: 400);
}
