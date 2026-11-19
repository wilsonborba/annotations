import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/settings.dart';
import 'controls.dart';
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

class PageShell extends StatelessWidget {
  final Widget child;
  const PageShell({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Navigation links need room beside the language switcher.
    final wide = width > 940;
    final prefs = AppScope.of(context).preferences;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: width > 740 ? 34 : 12,
        title: track(
          'shell.navigation.home',
          AppBrand(
            homeLabel: context.tr('home'),
            showTitle: width >= 430,
            onHome: () => context.go('/v1/home'),
          ),
        ),
        actions: [
          if (wide) ...[
            track(
              'shell.navigation.notes',
              AppButton.subtle(
                label: context.tr('notes'),
                onPressed: () => context.go('/v1/menu'),
              ),
            ),
            const SizedBox(width: 4),
            track(
              'shell.navigation.instant',
              AppButton.subtle(
                label: context.tr('instant'),
                onPressed: () => context.go('/v1/instant'),
              ),
            ),
            const SizedBox(width: 16),
          ],
          LanguageSwitch(selected: prefs.locale, onChanged: prefs.language),
          const SizedBox(width: 6),
          track(
            'shell.theme.toggle',
            AppIconButton.navigation(
              key: const Key('theme-toggle'),
              icon: AppIcons.contrast,
              label: context.tr('theme'),
              onPressed: () => prefs.toggle(dark),
            ),
          ),
          if (!wide)
            track(
              'shell.navigation.menu',
              AppMenuButton(
                icon: AppIcons.menu,
                label: context.tr('menu'),
                round: true,
                entries: [
                  for (final (route, key) in const [
                    ('/v1/menu', 'notes'),
                    ('/v1/instant', 'instant'),
                  ])
                    AppMenuEntry(
                      label: context.tr(key),
                      onSelected: () {
                        trackChoice(context, 'shell.navigation.menu', route);
                        context.go(route);
                      },
                    ),
                ],
              ),
            ),
          const SizedBox(width: 12),
        ],
      ),
      // The router's navigator fills the body; each page scrolls on its
      // own (ShellPage). A scroll view around the navigator gave the
      // outgoing page the height of the incoming one during a transition
      // (annotations#58).
      body: child,
    );
  }
}

/// One page of the shell: the page and the footer in their own scroll
/// view, so a page transition never sizes one page by another.
class ShellPage extends StatelessWidget {
  final Widget child;
  const ShellPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [child, const Footer()],
    ),
  );
}

/// Interface language: the same segmented switcher as the other Asodya apps.
class LanguageSwitch extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;
  const LanguageSwitch({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = Theme.of(context).textTheme.labelMedium!;
    return Tooltip(
      message: context.tr('language'),
      child: Container(
        key: const Key('language-switch'),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.subtle,
          borderRadius: BorderRadius.circular(appRadius + 2),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (code, text) in const [
              ('en', 'EN'),
              ('pt-BR', 'PT'),
              ('th', 'TH'),
            ])
              track(
                code == 'en'
                    ? 'shell.language.english'
                    : code == 'th'
                    ? 'shell.language.thai'
                    : 'shell.language.portuguese',
                Semantics(
                  selected: code == selected,
                  child: InkWell(
                    key: Key('language-$code'),
                    onTap: () {
                      trackChoice(context, 'shell.language.select', code);
                      onChanged(code);
                    },
                    borderRadius: BorderRadius.circular(appRadius),
                    // The current choice is a selection: green fill, dark text.
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: code == selected
                            ? c.selection
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(appRadius),
                        border: Border.all(
                          color: code == selected && !c.isDark
                              ? c.selectionOutline
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        text,
                        style: label.copyWith(
                          color: code == selected
                              ? c.onSelection
                              : c.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
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
            'v${Settings.current.version} · ${Settings.current.buildTime}',
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
  Widget build(BuildContext context) => track(
    url.contains('/docs') ? 'shell.footer.api' : 'shell.footer.about',
    InkWell(
      onTap: () => launchUrl(Uri.parse(url)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: context.colors.link,
          ),
        ),
      ),
    ),
  );
}

/// Missing or private content: no retry, because trying again cannot reveal it.
class NotFoundState extends StatelessWidget {
  const NotFoundState({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        AppIcon(AppIcons.search, size: 32, color: context.colors.iconSecondary),
        const SizedBox(height: 12),
        Text(context.tr('notFound'), key: const Key('not-found')),
        const SizedBox(height: 12),
        track(
          'shell.error.back',
          AppButton(
            label: context.tr('back'),
            icon: AppIcons.chevronLeft,
            onPressed: () => context.go('/v1/menu'),
          ),
        ),
      ],
    ),
  );
}

/// A failed load: short message, the error reference code and Retry.
class LoadError extends StatelessWidget {
  final VoidCallback retry;

  /// The reference code of the reported error, when one exists.
  final String? reference;
  const LoadError({super.key, required this.retry, this.reference});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        AppIcon(
          AppIcons.cloudDisconnected,
          size: 32,
          color: context.colors.danger,
        ),
        const SizedBox(height: 12),
        Text(context.tr('error')),
        if (reference != null) ...[
          const SizedBox(height: 6),
          Text(
            '${context.tr('reference')}: $reference',
            key: const Key('error-reference'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        track(
          'shell.error.retry',
          AppButton(label: context.tr('retry'), onPressed: retry),
        ),
      ],
    ),
  );
}
