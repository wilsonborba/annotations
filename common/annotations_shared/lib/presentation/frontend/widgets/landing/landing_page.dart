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
import 'landing_blocks.dart';

/// Overview, /v1/home (H6 section 3 point 5): what Annotations is, the one
/// strong action, the two modes, the platform groups, the training notice
/// and the recent public notes.
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
      ImageRow(
        image: 'O01',
        imageRight: true,
        child: RowText(
          page: true,
          title: context.tr('overviewTitle'),
          lead: context.tr('overviewLead'),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // The one high-attention element of the page.
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
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('modesTitle')),
          CardLine(
            cards: [
              LandingCard(
                image: 'O02',
                title: context.tr('modeInstantTitle'),
                text: context.tr('modeInstantText'),
              ),
              LandingCard(
                image: 'O03',
                title: context.tr('modeNotesTitle'),
                text: context.tr('modeNotesText'),
              ),
            ],
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('startTitle')),
          CardLine(
            cards: [
              LandingCard(
                image: 'O04',
                title: context.tr('actionBrowse'),
                text: context.tr('startBrowseText'),
                trackId: 'landing.card.browse',
                onOpen: () => context.go('/v1/menu'),
              ),
              LandingCard(
                image: 'O05',
                title: context.tr('actionInstant'),
                text: context.tr('startInstantText'),
                trackId: 'landing.card.instant',
                onOpen: () => context.go('/v1/instant'),
              ),
              LandingCard(
                image: 'O06',
                title: context.tr('actionDownload'),
                text: context.tr('startDownloadText'),
                trackId: 'landing.card.download',
                onOpen: () => context.go('/v1/home/download'),
              ),
            ],
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('platformsTitle')),
          CardLine(
            cards: [
              LandingCard(
                image: 'O07',
                title: context.tr('platformWritersTitle'),
                text: context.tr('platformWritersText'),
              ),
              LandingCard(
                image: 'O08',
                title: context.tr('platformPhonesTitle'),
                text: context.tr('platformPhonesText'),
              ),
              LandingCard(
                image: 'O09',
                title: context.tr('platformBrowserTitle'),
                text: context.tr('platformBrowserText'),
              ),
            ],
          ),
        ],
      ),
      const TrainingNotice(band: true),
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
