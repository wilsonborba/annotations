import 'package:flutter/material.dart';
import 'package:screen_trail/screen_trail.dart';
export 'package:screen_trail/screen_trail.dart';

// Keep these identities synchronized with tracking_manifest.json.
const annotationScreens = <TrailScreen>[
  TrailScreen(
    name: 'features',
    route: '/v1/home/features',
    label: 'Annotations features',
  ),
  TrailScreen(
    name: 'how_it_works',
    route: '/v1/home/how-it-works',
    label: 'Annotations how it works',
  ),
  TrailScreen(
    name: 'engineering',
    route: '/v1/home/engineering',
    label: 'Annotations engineering',
  ),
  TrailScreen(
    name: 'download',
    route: '/v1/home/download',
    label: 'Annotations download',
  ),
  TrailScreen(name: 'landing', route: '/v1/home', label: 'Annotations home'),
  TrailScreen(name: 'catalog', route: '/v1/menu', label: 'Articles catalog'),
  TrailScreen(
    name: 'article',
    route: '/v1/menu/:channel/:slug',
    label: 'Article',
  ),
  TrailScreen(name: 'instant', route: '/v1/instant', label: 'Instant Share'),
  TrailScreen(
    name: 'instant',
    route: '/v1/instant/:code',
    label: 'Instant Share room',
    sensitivePath: true,
  ),
];
const annotationElements = <String, TrailElement>{
  'landing.card.notes': TrailElement(
    id: 'landing.card.notes',
    label: 'Landing card notes',
    path: 'landing > card > notes',
  ),
  'landing.card.feature': TrailElement(
    id: 'landing.card.feature',
    label: 'Landing card feature',
    path: 'landing > card > feature',
  ),
  'landing.showcase.select': TrailElement(
    id: 'landing.showcase.select',
    label: 'Landing showcase select',
    path: 'landing > showcase > select',
  ),
  'landing.install.action': TrailElement(
    id: 'landing.install.action',
    label: 'Landing install action',
    path: 'landing > install > action',
  ),
  'landing.install.how': TrailElement(
    id: 'landing.install.how',
    label: 'Landing install how',
    path: 'landing > install > how',
  ),
  'shell.navigation.overview': TrailElement(
    id: 'shell.navigation.overview',
    label: 'Shell navigation overview',
    path: 'shell > navigation > overview',
  ),
  'shell.navigation.features': TrailElement(
    id: 'shell.navigation.features',
    label: 'Shell navigation features',
    path: 'shell > navigation > features',
  ),
  'shell.navigation.how_it_works': TrailElement(
    id: 'shell.navigation.how_it_works',
    label: 'Shell navigation how it works',
    path: 'shell > navigation > how_it_works',
  ),
  'shell.navigation.engineering': TrailElement(
    id: 'shell.navigation.engineering',
    label: 'Shell navigation engineering',
    path: 'shell > navigation > engineering',
  ),
  'shell.navigation.download': TrailElement(
    id: 'shell.navigation.download',
    label: 'Shell navigation download',
    path: 'shell > navigation > download',
  ),
  'landing.download.open': TrailElement(
    id: 'landing.download.open',
    label: 'Landing download open',
    path: 'landing > download > open',
  ),
  'landing.card.instant': TrailElement(
    id: 'landing.card.instant',
    label: 'Landing card instant',
    path: 'landing > card > instant',
  ),
  'landing.notice.terms': TrailElement(
    id: 'landing.notice.terms',
    label: 'Landing notice terms',
    path: 'landing > notice > terms',
  ),
  'landing.notice.privacy': TrailElement(
    id: 'landing.notice.privacy',
    label: 'Landing notice privacy',
    path: 'landing > notice > privacy',
  ),
  'engineering.diagram.open': TrailElement(
    id: 'engineering.diagram.open',
    label: 'Engineering diagram open',
    path: 'engineering > diagram > open',
  ),
  'engineering.repo.open': TrailElement(
    id: 'engineering.repo.open',
    label: 'Engineering repo open',
    path: 'engineering > repo > open',
  ),
  'download.command.copy': TrailElement(
    id: 'download.command.copy',
    label: 'Download command copy',
    path: 'download > command > copy',
  ),
  'download.releases.open': TrailElement(
    id: 'download.releases.open',
    label: 'Download releases open',
    path: 'download > releases > open',
  ),
  'download.repo.open': TrailElement(
    id: 'download.repo.open',
    label: 'Download repo open',
    path: 'download > repo > open',
  ),
  'features.surface': TrailElement(
    id: 'features.surface',
    label: 'Features surface',
    path: 'features > surface',
  ),
  'how_it_works.surface': TrailElement(
    id: 'how_it_works.surface',
    label: 'How it works surface',
    path: 'how_it_works > surface',
  ),
  'engineering.surface': TrailElement(
    id: 'engineering.surface',
    label: 'Engineering surface',
    path: 'engineering > surface',
  ),
  'download.surface': TrailElement(
    id: 'download.surface',
    label: 'Download surface',
    path: 'download > surface',
  ),
  'landing.catalog.all': TrailElement(
    id: 'landing.catalog.all',
    label: 'Landing catalog all',
    path: 'landing > catalog > all',
  ),
  'landing.instant.open': TrailElement(
    id: 'landing.instant.open',
    label: 'Landing instant open',
    path: 'landing > instant > open',
  ),
  'landing.browse.open': TrailElement(
    id: 'landing.browse.open',
    label: 'Landing browse open',
    path: 'landing > browse > open',
  ),
  'catalog.pagination.more': TrailElement(
    id: 'catalog.pagination.more',
    label: 'Catalog pagination more',
    path: 'catalog > pagination > more',
  ),
  'catalog.channel.select': TrailElement(
    id: 'catalog.channel.select',
    label: 'Catalog channel select',
    path: 'catalog > channel > select',
  ),
  'catalog.topic.select': TrailElement(
    id: 'catalog.topic.select',
    label: 'Catalog topic select',
    path: 'catalog > topic > select',
  ),
  'catalog.search.input': TrailElement(
    id: 'catalog.search.input',
    label: 'Catalog search input',
    path: 'catalog > search > input',
  ),
  'article.author.open': TrailElement(
    id: 'article.author.open',
    label: 'Article author open',
    path: 'article > author > open',
  ),
  'article.content_language.dropdown': TrailElement(
    id: 'article.content_language.dropdown',
    label: 'Article content language dropdown',
    path: 'article > content_language > dropdown',
  ),
  'article.share.copy': TrailElement(
    id: 'article.share.copy',
    label: 'Article share copy',
    path: 'article > share > copy',
  ),
  'article.catalog.back': TrailElement(
    id: 'article.catalog.back',
    label: 'Article catalog back',
    path: 'article > catalog > back',
  ),
  'instant.room.open': TrailElement(
    id: 'instant.room.open',
    label: 'Instant room open',
    path: 'instant > room > open',
  ),
  'instant.room.code': TrailElement(
    id: 'instant.room.code',
    label: 'Instant room code',
    path: 'instant > room > code',
  ),
  'instant.item.download': TrailElement(
    id: 'instant.item.download',
    label: 'Instant item download',
    path: 'instant > item > download',
  ),
  'instant.item.edit': TrailElement(
    id: 'instant.item.edit',
    label: 'Instant item edit',
    path: 'instant > item > edit',
  ),
  'instant.item.link': TrailElement(
    id: 'instant.item.link',
    label: 'Instant item link',
    path: 'instant > item > link',
  ),
  'instant.room.copy': TrailElement(
    id: 'instant.room.copy',
    label: 'Instant room copy',
    path: 'instant > room > copy',
  ),
  'instant.room.reopen': TrailElement(
    id: 'instant.room.reopen',
    label: 'Instant room reopen',
    path: 'instant > room > reopen',
  ),
  'instant.composer.upload': TrailElement(
    id: 'instant.composer.upload',
    label: 'Instant composer upload',
    path: 'instant > composer > upload',
  ),
  'instant.composer.add': TrailElement(
    id: 'instant.composer.add',
    label: 'Instant composer add',
    path: 'instant > composer > add',
  ),
  'instant.composer.text': TrailElement(
    id: 'instant.composer.text',
    label: 'Instant composer text',
    path: 'instant > composer > text',
  ),
  'instant.item.remove': TrailElement(
    id: 'instant.item.remove',
    label: 'Instant item remove',
    path: 'instant > item > remove',
  ),
  'instant.edit.save': TrailElement(
    id: 'instant.edit.save',
    label: 'Instant edit save',
    path: 'instant > edit > save',
  ),
  'instant.edit.cancel': TrailElement(
    id: 'instant.edit.cancel',
    label: 'Instant edit cancel',
    path: 'instant > edit > cancel',
  ),
  'instant.edit.content': TrailElement(
    id: 'instant.edit.content',
    label: 'Instant edit content',
    path: 'instant > edit > content',
  ),
  'article.media.report': TrailElement(
    id: 'article.media.report',
    label: 'Article media report',
    path: 'article > media > report',
  ),
  'article.media.link': TrailElement(
    id: 'article.media.link',
    label: 'Article media link',
    path: 'article > media > link',
  ),
  'catalog.article.open': TrailElement(
    id: 'catalog.article.open',
    label: 'Catalog article open',
    path: 'catalog > article > open',
  ),
  'shell.error.retry': TrailElement(
    id: 'shell.error.retry',
    label: 'Shell error retry',
    path: 'shell > error > retry',
  ),
  'shell.error.back': TrailElement(
    id: 'shell.error.back',
    label: 'Shell error back',
    path: 'shell > error > back',
  ),
  'shell.footer.link': TrailElement(
    id: 'shell.footer.link',
    label: 'Shell footer link',
    path: 'shell > footer > link',
  ),
  'shell.language.select': TrailElement(
    id: 'shell.language.select',
    label: 'Shell language select',
    path: 'shell > language > select',
  ),
  'shell.navigation.menu': TrailElement(
    id: 'shell.navigation.menu',
    label: 'Shell navigation menu',
    path: 'shell > navigation > menu',
  ),
  'shell.theme.toggle': TrailElement(
    id: 'shell.theme.toggle',
    label: 'Shell theme toggle',
    path: 'shell > theme > toggle',
  ),
  'shell.navigation.instant': TrailElement(
    id: 'shell.navigation.instant',
    label: 'Shell navigation instant',
    path: 'shell > navigation > instant',
  ),
  'shell.navigation.notes': TrailElement(
    id: 'shell.navigation.notes',
    label: 'Shell navigation notes',
    path: 'shell > navigation > notes',
  ),
  'shell.navigation.home': TrailElement(
    id: 'shell.navigation.home',
    label: 'Shell navigation home',
    path: 'shell > navigation > home',
  ),
  'shell.language.english': TrailElement(
    id: 'shell.language.english',
    label: 'Shell language english',
    path: 'shell > language > english',
  ),
  'shell.language.portuguese': TrailElement(
    id: 'shell.language.portuguese',
    label: 'Shell language portuguese',
    path: 'shell > language > portuguese',
  ),
  'shell.language.thai': TrailElement(
    id: 'shell.language.thai',
    label: 'Shell language thai',
    path: 'shell > language > thai',
  ),
  'landing.surface': TrailElement(
    id: 'landing.surface',
    label: 'Landing surface',
    path: 'landing > surface',
  ),
  'catalog.surface': TrailElement(
    id: 'catalog.surface',
    label: 'Catalog surface',
    path: 'catalog > surface',
  ),
  'article.surface': TrailElement(
    id: 'article.surface',
    label: 'Article surface',
    path: 'article > surface',
  ),
  'instant.surface': TrailElement(
    id: 'instant.surface',
    label: 'Instant surface',
    path: 'instant > surface',
  ),
};

/// Fields whose typed value never leaves the device. Add every field that
/// holds note text, transcription drafts, credentials or room codes.
const sensitiveElements = <String>{
  'instant.room.code',
  'instant.composer.text',
  'instant.edit.content',
};

Widget track(
  String id,
  Widget child, {
  TextEditingController? controller,
  bool sensitive = false,
}) {
  final element = annotationElements[id]!;
  return controller == null
      ? TrackedElement(element: element, child: child)
      : TrackedInput(
          element: element,
          controller: controller,
          sensitive: sensitive || sensitiveElements.contains(id),
          child: child,
        );
}

void trackSubmit(BuildContext context, String id) =>
    ScreenTrailScope.maybeOf(context)?.event('submit', annotationElements[id]!);
void trackChoice(BuildContext context, String id, String? value) =>
    ScreenTrailScope.maybeOf(
      context,
    )?.event('input', annotationElements[id]!, value: value);
