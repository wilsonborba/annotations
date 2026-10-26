import 'package:flutter/material.dart';
import '../../../domain/models/content.dart';

class BodyBlocks extends StatelessWidget {
  final Data body;
  const BodyBlocks({super.key, required this.body});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: records(body['blocks'])
        .map(
          (block) => Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: blockWidget(context, block),
          ),
        )
        .toList(),
  );
  Widget blockWidget(BuildContext context, Data block) {
    final text = (block['text'] ?? '').toString();
    final type = block['type'];
    final theme = Theme.of(context);
    var color = theme.colorScheme.onSurface;
    if (block['color'] == 'muted') color = theme.colorScheme.onSurfaceVariant;
    if (block['color'] == 'purple') color = theme.colorScheme.primary;
    if (block['color'] == 'green') {
      color = theme.brightness == Brightness.dark
          ? const Color(0xFF8BDCA8)
          : const Color(0xFF187A3D);
    }
    final style =
        (type == 'heading'
                ? theme.textTheme.headlineMedium
                : theme.textTheme.bodyLarge)
            ?.copyWith(
              color: color,
              fontWeight: block['bold'] == true || type == 'heading'
                  ? FontWeight.w700
                  : FontWeight.w400,
              fontStyle: block['italic'] == true
                  ? FontStyle.italic
                  : FontStyle.normal,
              decoration: block['underline'] == true
                  ? TextDecoration.underline
                  : TextDecoration.none,
            );
    switch (type) {
      case 'heading':
        return Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Text(text, style: style),
        );
      case 'quote':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              left: BorderSide(color: theme.colorScheme.primary, width: 3),
            ),
          ),
          child: Text(text, style: style),
        );
      case 'list':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: labels(block['items'])
              .asMap()
              .entries
              .map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${e.key + 1}.', style: style),
                      const SizedBox(width: 14),
                      Expanded(child: Text(e.value, style: style)),
                    ],
                  ),
                ),
              )
              .toList(),
        );
      case 'paragraph':
        return Text(text, style: style);
      default:
        return const SizedBox.shrink();
    }
  }
}
