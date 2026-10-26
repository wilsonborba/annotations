import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/settings.dart';
import 'scope.dart';

class PageShell extends StatelessWidget {
  final Widget child;
  const PageShell({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 740;
    final prefs = AppScope.of(context).preferences;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 80,
        titleSpacing: wide ? 40 : 18,
        title: InkWell(
          onTap: () => context.go('/v1/home'),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'lib/presentation/frontend/assets/images/asodya_logo.png',
                height: 29,
              ),
              const SizedBox(width: 12),
              const Text(
                'Annotations',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        actions: [
          if (wide) ...[
            TextButton(
              onPressed: () => context.go('/v1/menu'),
              child: Text(context.tr('notes')),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => context.go('/v1/instant'),
              child: Text(context.tr('instant')),
            ),
            const SizedBox(width: 16),
          ],
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: prefs.locale,
              iconSize: 17,
              items: const [
                DropdownMenuItem(value: 'en', child: Text('EN')),
                DropdownMenuItem(value: 'pt-BR', child: Text('PT')),
                DropdownMenuItem(value: 'th', child: Text('TH')),
              ],
              onChanged: (v) {
                if (v != null) prefs.language(v);
              },
            ),
          ),
          IconButton(
            key: const Key('theme-toggle'),
            tooltip: context.tr('theme'),
            onPressed: () => prefs.toggle(dark),
            icon: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.85),
            ),
          ),
          if (!wide)
            PopupMenuButton<String>(
              onSelected: context.go,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: '/v1/menu',
                  child: Text(context.tr('notes')),
                ),
                PopupMenuItem(
                  value: '/v1/instant',
                  child: Text(context.tr('instant')),
                ),
              ],
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [child, const Footer()],
        ),
      ),
    );
  }
}

class ContentWidth extends StatelessWidget {
  final Widget child;
  final double width;
  final EdgeInsets? padding;
  const ContentWidth({
    super.key,
    required this.child,
    this.width = 1180,
    this.padding,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: Padding(
        padding:
            padding ??
            EdgeInsets.symmetric(
              horizontal: MediaQuery.sizeOf(context).width > 740 ? 32 : 20,
              vertical: 40,
            ),
        child: child,
      ),
    ),
  );
}

class Footer extends StatelessWidget {
  const Footer({super.key});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 64),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: ContentWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ANNOTATIONS',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.6),
          ),
          const SizedBox(height: 12),
          Text(context.tr('footer')),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              FooterLink(
                key: const Key('footer-about'),
                label: context.tr('aboutUs'),
                url: 'https://asodya.com',
              ),
              const FooterLink(
                key: Key('footer-api'),
                label: 'API',
                url: 'https://api.asodya.com/docs',
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'v${Settings.version} · ${Settings.buildTime}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class FooterLink extends StatelessWidget {
  final String label, url;
  const FooterLink({super.key, required this.label, required this.url});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => launchUrl(Uri.parse(url)),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class LoadError extends StatelessWidget {
  final VoidCallback retry;
  const LoadError({super.key, required this.retry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        const Icon(Icons.cloud_off_outlined, size: 32),
        const SizedBox(height: 12),
        Text(context.tr('error')),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: retry, child: Text(context.tr('retry'))),
      ],
    ),
  );
}
