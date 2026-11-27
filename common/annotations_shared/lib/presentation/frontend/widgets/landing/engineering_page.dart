import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/landing_settings.dart';
import '../../components/controls.dart';
import '../../components/interactive_card.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/sketch_art.dart';
import '../../components/sketch_diagram.dart';
import 'landing_blocks.dart';

/// Engineering, /v1/home/engineering (H6 section 3 point 8): diagrams drawn
/// in code instead of code snippets (58edb2df). Each part links to its
/// public repository at a tagged version.
class EngineeringPage extends StatelessWidget {
  const EngineeringPage({super.key});

  @override
  Widget build(BuildContext context) {
    void open(PublicRepo repo) {
      trackChoice(context, 'engineering.diagram.open', repo.name);
      launchUrl(Uri.parse(repo.url));
    }

    return LandingBody(
      children: [
        RowText(
          page: true,
          title: context.tr('engTitle'),
          lead: context.tr('engLead'),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              context.tr('engArchitectureTitle'),
              lead: context.tr('engArchitectureText'),
            ),
            SketchDiagram(
              name: 'architecture',
              stages: architectureStages,
              onOpen: open,
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              context.tr('engRulesTitle'),
              lead: context.tr('engRulesText'),
            ),
            SketchDiagram(name: 'rules', stages: rulesStages, onOpen: open),
          ],
        ),
        VisualRow(
          rowKey: const Key('row-open-source'),
          // Drawn in code; the site has no photographs (owner, 2026-11-24).
          visual: const SketchArt(
            SketchScene.openSource,
            key: Key('art-open-source'),
          ),
          visualRight: false,
          child: RowText(
            title: context.tr('engSourceTitle'),
            lead: context.tr('engSourceText'),
            children: [
              Column(
                key: const Key('repo-list'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final repo in LandingSettings.repos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: track(
                        'engineering.repo.open',
                        AppLink(
                          key: Key('repo-${repo.name}'),
                          label: '${repo.name} ${repo.tag}',
                          onTap: () {
                            trackChoice(
                              context,
                              'engineering.repo.open',
                              repo.name,
                            );
                            launchUrl(Uri.parse(repo.url));
                          },
                        ),
                      ),
                    ),
                ],
              ),
              track(
                'download.repo.open',
                AppButton.primary(
                  key: const Key('engineering-source'),
                  label: context.tr('repoLink'),
                  icon: AppIcons.openIn,
                  onPressed: () =>
                      launchUrl(Uri.parse(LandingSettings.app.url)),
                ),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              context.tr('engModelTitle'),
              lead: context.tr('engModelText'),
            ),
            SketchDiagram(name: 'model', stages: modelStages, onOpen: open),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              context.tr('engTrackingTitle'),
              lead: context.tr('engTrackingText'),
            ),
            SketchDiagram(
              name: 'tracking',
              stages: trackingStages,
              onOpen: open,
            ),
          ],
        ),
      ],
    );
  }
}
