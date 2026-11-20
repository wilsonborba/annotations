import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/landing_settings.dart';
import '../../components/scope.dart';
import '../../components/sketch_diagram.dart';
import '../../components/tokens.dart';
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
        ImageRow(
          image: 'E01',
          imageRight: true,
          child: RowText(
            page: true,
            title: context.tr('engTitle'),
            lead: context.tr('engLead'),
          ),
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
        ImageRow(
          image: 'E02',
          imageRight: false,
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
                        Semantics(
                          link: true,
                          child: InkWell(
                            key: Key('repo-${repo.name}'),
                            onTap: () {
                              trackChoice(
                                context,
                                'engineering.repo.open',
                                repo.name,
                              );
                              launchUrl(Uri.parse(repo.url));
                            },
                            child: Text(
                              '${repo.name} ${repo.tag}',
                              style: Theme.of(context).textTheme.bodyMedium!
                                  .copyWith(
                                    color: context.colors.link,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                    decorationColor: context.colors.link,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        ImageRow(
          image: 'E03',
          imageRight: true,
          child: RowText(
            title: context.tr('engModelTitle'),
            lead: context.tr('engModelText'),
          ),
        ),
        SketchDiagram(name: 'model', stages: modelStages, onOpen: open),
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
