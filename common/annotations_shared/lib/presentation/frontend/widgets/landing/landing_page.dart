import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:annotations_shared/core/tracking.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../domain/models/content.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/post_card.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../handlers/content_handler.dart';
import '../../../../core/landing_settings.dart';
import '../../components/interactive_card.dart';
import '../../components/sketch_art.dart';
import '../../components/tokens.dart';
import 'features_page.dart' show groupPair;
import 'landing_blocks.dart';
import 'landing_sections.dart';

/// Overview, /v1/home (H6 section 3 point 5, owner direction 2026-11-20):
/// the hero with the one strong action, the product showcase, the install
/// blocks, the two modes, three feature cards, the training notice and the
/// recent public notes.
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});
  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  Future<Data>? latest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    latest ??= ContentHandler(AppScope.of(context).service).articles();
  }

  @override
  Widget build(BuildContext context) => LandingBody(
    children: [
      // 1. Hero: Notion-scale headline with the animated word, the one
      // strong action and the secondary actions.
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: const AnimatedHeadline(),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              context.tr('overviewLead'),
              style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                fontSize: isPhone(context) ? 17 : 20,
                color: context.colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              track(
                'landing.download.open',
                AppButton.primary(
                  key: const Key('overview-download'),
                  label: context.tr('actionDownload'),
                  icon: AppIcons.download,
                  onPressed: () => context.go('/v1/home/download'),
                ),
              ),
              track(
                'landing.browse.open',
                AppButton(
                  key: const Key('overview-browse'),
                  label: context.tr('actionBrowse'),
                  onPressed: () => context.go('/v1/menu'),
                ),
              ),
              track(
                'landing.instant.open',
                AppButton(
                  key: const Key('overview-instant'),
                  label: context.tr('actionInstant'),
                  onPressed: () => context.go('/v1/instant'),
                ),
              ),
            ],
          ),
        ],
      ),
      // 2. The product showcase with real screenshots.
      const ProductShowcase(),
      // 3. Install, one block per platform.
      Column(
        key: const Key('install-section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(
            context.tr('installTitle'),
            lead: context.tr('downloadLead'),
          ),
          const InstallGrid(),
        ],
      ),
      // 4. Two key ideas side by side: the two modes.
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('modesTitle')),
          CardRow(
            children: [
              IllustratedCard(
                key: const Key('card-notes'),
                scene: SketchScene.notes,
                title: context.tr('modeNotesTitle'),
                body: context.tr('modeNotesText'),
                trackId: 'landing.card.notes',
                onTap: () => context.go('/v1/home/how-it-works'),
              ),
              IllustratedCard(
                key: const Key('card-instant'),
                scene: SketchScene.instant,
                title: context.tr('modeInstantTitle'),
                body: context.tr('modeInstantText'),
                trackId: 'landing.card.instant',
                onTap: () => context.go('/v1/instant'),
              ),
            ],
          ),
        ],
      ),
      // 5. Three feature cards with drawn illustrations.
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SectionTitle(
                  context.tr('featuresTitle'),
                  lead: context.tr('groupWritingText'),
                ),
              ),
              if (!isPhone(context))
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: AppLink(
                    key: const Key('overview-all-features'),
                    label: context.tr('allFeatures'),
                    trailing: true,
                    onTap: () => context.go('/v1/home/features'),
                  ),
                ),
            ],
          ),
          CardRow(
            children: [
              for (final (scene, group, title, body) in [
                (
                  SketchScene.writing,
                  FeatureGroup.writing,
                  'groupWriting',
                  'featureF03Text',
                ),
                (
                  SketchScene.chart,
                  FeatureGroup.pageContent,
                  'featureF08Title',
                  'featureF08Text',
                ),
                (
                  SketchScene.tasks,
                  FeatureGroup.pageContent,
                  'featureF09Title',
                  'featureF09Text',
                ),
              ])
                IllustratedCard(
                  key: Key('card-${scene.name}'),
                  scene: scene,
                  pair: groupPair(group),
                  title: context.tr(title),
                  body: context.tr(body),
                  trackId: 'landing.card.feature',
                  onTap: () => context.go('/v1/home/features'),
                ),
            ],
          ),
        ],
      ),
      const TrainingNotice(),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: SectionTitle(context.tr('recentTitle'))),
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: track(
                  'landing.catalog.all',
                  AppButton.subtle(
                    label: context.tr('recentAll'),
                    trailingIcon: AppIcons.chevronRight,
                    onPressed: () => context.go('/v1/menu'),
                  ),
                ),
              ),
            ],
          ),
          FutureBuilder<Data>(
            future: latest,
            builder: (context, s) {
              if (s.hasError) {
                return LoadError(
                  reference: ClientErrors.referenceOf(s.error),
                  retry: () => setState(
                    () => latest = ContentHandler(
                      AppScope.of(context).service,
                    ).articles(),
                  ),
                );
              }
              if (!s.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(30),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final items = records(s.data!['items']);
              return items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Text(context.tr('empty')),
                    )
                  : PostGrid(items: items.take(6).toList());
            },
          ),
        ],
      ),
    ],
  );
}
