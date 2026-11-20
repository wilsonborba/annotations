import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/landing_settings.dart';
import '../../../core/settings.dart';
import 'controls.dart';
import 'landing_image.dart';
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

/// The landing tabs (H6 section 3 point 2), one page each.
const landingTabs = <(String, String, String)>[
  ('/v1/home', 'tabOverview', 'shell.navigation.overview'),
  ('/v1/home/features', 'tabFeatures', 'shell.navigation.features'),
  ('/v1/home/how-it-works', 'tabHowItWorks', 'shell.navigation.how_it_works'),
  ('/v1/home/engineering', 'tabEngineering', 'shell.navigation.engineering'),
  ('/v1/home/download', 'tabDownload', 'shell.navigation.download'),
];

/// At this width and below the tabs go into one menu (Cortex pattern).
const tabsMenuWidth = 1000.0;

class PageShell extends StatelessWidget {
  final Widget child;

  /// The path of the current page, to mark the current tab.
  final String location;
  const PageShell({super.key, required this.child, this.location = ''});
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width > tabsMenuWidth;
    final prefs = AppScope.of(context).preferences;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        titleSpacing: width > 740 ? 34 : 12,
        title: Row(
          children: [
            track(
              'shell.navigation.home',
              AppBrand(
                homeLabel: context.tr('home'),
                // Beside the tabs the title needs a wide window.
                showTitle: wide ? width >= 1180 : width >= 430,
                onHome: () => context.go('/v1/home'),
              ),
            ),
            if (wide) ...[
              const SizedBox(width: 4),
              for (final (route, key, id) in landingTabs)
                track(
                  id,
                  ShellTab(
                    key: Key('tab-$key'),
                    label: context.tr(key),
                    selected: location == route,
                    onPressed: () => context.go(route),
                  ),
                ),
            ],
          ],
        ),
        actions: [
          if (wide) ...[
            track(
              'shell.navigation.notes',
              AppButton.subtle(
                key: const Key('bar-notes'),
                label: context.tr('barNotes'),
                onPressed: () => context.go('/v1/menu'),
              ),
            ),
            const SizedBox(width: 4),
            track(
              'shell.navigation.instant',
              AppButton.subtle(
                key: const Key('bar-instant'),
                label: context.tr('barInstant'),
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
                key: const Key('tabs-menu'),
                icon: AppIcons.menu,
                label: context.tr('menu'),
                round: true,
                entries: [
                  for (final (route, key) in [
                    for (final (route, key, _) in landingTabs) (route, key),
                    ('/v1/menu', 'barNotes'),
                    ('/v1/instant', 'barInstant'),
                  ])
                    AppMenuEntry(
                      key: Key('menu-$key'),
                      label: context.tr(key),
                      checked: location == route,
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

/// One tab of the top bar. The current tab is a selection: a green fill
/// with dark text, with the darker outline on light surfaces.
class ShellTab extends StatelessWidget {
  const ShellTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: TextButton(
          onPressed: onPressed,
          style:
              appButtonStyle(
                c,
                Theme.of(context).textTheme,
                AppButtonKind.subtle,
              ).copyWith(
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                backgroundColor: selected
                    ? WidgetStatePropertyAll(c.selection)
                    : null,
                foregroundColor: selected
                    ? WidgetStatePropertyAll(c.onSelection)
                    : null,
                side: selected && !c.isDark
                    ? WidgetStatePropertyAll(
                        BorderSide(color: c.selectionOutline),
                      )
                    : null,
              ),
          child: Text(label),
        ),
      ),
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

/// The footer (H6 section 3 point 10): Asodya, the other apps, the API
/// docs, the public repositories, Terms, Privacy and the build version.
class Footer extends StatelessWidget {
  const Footer({super.key});
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      key: const Key('footer'),
      margin: const EdgeInsets.only(top: 64),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: ContentWidth(
        width: 1264,
        // Full content width, so the footer lines up with the page.
        child: SizedBox(
          width: double.infinity,
          child: Column(
            key: const Key('footer-content'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  for (final (label, url) in [
                    ('Asodya', LandingSettings.asodya),
                    ('Reports', LandingSettings.reports),
                    ('Certifications', LandingSettings.certifications),
                    ('Cortex', LandingSettings.cortex),
                    (context.tr('footerApiDocs'), LandingSettings.apiDocs),
                    (context.tr('terms'), LandingSettings.terms),
                    (context.tr('privacy'), LandingSettings.privacy),
                  ])
                    FooterLink(label: label, url: url),
                ],
              ),
              const SizedBox(height: 16),
              Text(context.tr('footerSource'), style: text.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 20,
                runSpacing: 6,
                children: [
                  for (final repo in LandingSettings.repos)
                    FooterLink(label: repo.name, url: repo.url),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '${context.tr('footerBuild')} ${Settings.current.version} (${Settings.current.buildTime})',
                key: const Key('footer-build'),
                style: text.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FooterLink extends StatelessWidget {
  final String label, url;
  const FooterLink({super.key, required this.label, required this.url});
  @override
  Widget build(BuildContext context) => track(
    'shell.footer.link',
    Semantics(
      link: true,
      child: InkWell(
        key: Key('footer-$url'),
        onTap: () {
          trackChoice(context, 'shell.footer.link', url);
          launchUrl(Uri.parse(url));
        },
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
        const StatePicture('S01'),
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
