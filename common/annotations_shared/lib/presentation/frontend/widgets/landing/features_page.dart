import 'package:flutter/material.dart';

import '../../../../core/landing_settings.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../handlers/landing_handler.dart';
import 'landing_blocks.dart';

/// Features, /v1/home/features (H6 section 3 point 6): only the features in
/// the release, one row per feature with alternating sides, and what each
/// one needs.
class FeaturesPage extends StatelessWidget {
  const FeaturesPage({super.key, this.handler = const LandingHandler()});

  final LandingHandler handler;

  static const _groupKeys = {
    FeatureGroup.writing: 'groupWriting',
    FeatureGroup.pageContent: 'groupPageContent',
    FeatureGroup.study: 'groupStudy',
    FeatureGroup.sharing: 'groupSharing',
  };

  static const _groupIcons = {
    FeatureGroup.writing: AppIcons.roundPen,
    FeatureGroup.pageContent: AppIcons.file,
    FeatureGroup.study: AppIcons.fileText,
    FeatureGroup.sharing: AppIcons.peopleGroup,
  };

  @override
  Widget build(BuildContext context) => LandingBody(
    children: [
      RowText(
        page: true,
        title: context.tr('featuresTitle'),
        lead: context.tr('featuresLead'),
      ),
      for (final group in handler.groups)
        Column(
          key: Key('group-${group.name}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GroupHeading(
              group: group,
              title: context.tr(_groupKeys[group]!),
              lead: context.tr('${_groupKeys[group]!}Text'),
              icon: _groupIcons[group]!,
            ),
            for (final (i, row) in handler.rows(group).indexed) ...[
              SizedBox(height: isPhone(context) ? 40 : 56),
              // The first row of each group has its image on the right.
              ImageRow(
                image: row.image,
                imageRight: i.isEven,
                child: _FeatureText(row: row),
              ),
            ],
          ],
        ),
    ],
  );
}

/// The color pair of a group: the icon tile and the marks (H7 rule 6).
(Color, Color) groupPair(FeatureGroup group) =>
    AppPalette.pairs[group.index % AppPalette.pairs.length];

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.group,
    required this.title,
    required this.lead,
    required this.icon,
  });

  final FeatureGroup group;
  final String title;
  final String lead;
  final AppIconData icon;

  @override
  Widget build(BuildContext context) {
    final (tile, _) = groupPair(group);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A light fill with a dark icon, never light text on light paper.
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tile,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(icon, color: AppPalette.night, size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(child: SectionTitle(title, lead: lead)),
      ],
    );
  }
}

class _FeatureText extends StatelessWidget {
  const _FeatureText({required this.row});

  final LandingFeature row;

  @override
  Widget build(BuildContext context) {
    final (_, mark) = groupPair(row.group);
    final needs = switch (row.needs) {
      FeatureNeeds.nothing => 'needsNothing',
      FeatureNeeds.internet => 'needsInternet',
      FeatureNeeds.internetAndLogin => 'needsInternetAndLogin',
    };
    return RowText(
      title: context.tr('feature${row.image}Title'),
      lead: context.tr('feature${row.image}Text'),
      children: [
        Row(
          key: Key('needs-${row.image}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: mark,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                context.tr(needs),
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
