import 'package:flutter/material.dart';

import '../../components/scope.dart';
import '../../components/tokens.dart';
import 'landing_blocks.dart';

/// How it works, /v1/home/how-it-works (H6 section 3 point 7): the life of
/// a note, the life of an Instant room, handwriting to text, where notes
/// live, the training notice and the questions.
class HowItWorksPage extends StatelessWidget {
  const HowItWorksPage({super.key});

  static const faq = [
    ('faqLoginQ', 'faqLoginA'),
    ('faqSyncQ', 'faqSyncA'),
    ('faqInstantQ', 'faqInstantA'),
    ('faqBrowserQ', 'faqBrowserA'),
    ('faqTrainingQ', 'faqTrainingA'),
  ];

  @override
  Widget build(BuildContext context) => LandingBody(
    children: [
      RowText(page: true, title: context.tr('howTitle')),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('howNoteTitle')),
          CardLine(
            cards: [
              LandingCard(
                image: 'H01',
                title: context.tr('howWriteTitle'),
                text: context.tr('howWriteText'),
              ),
              LandingCard(
                image: 'H02',
                title: context.tr('howSignInTitle'),
                text: context.tr('howSignInText'),
              ),
              LandingCard(
                image: 'H03',
                title: context.tr('howPublishTitle'),
                text: context.tr('howPublishText'),
              ),
            ],
          ),
        ],
      ),
      ImageRow(
        image: 'H04',
        imageRight: true,
        child: RowText(
          title: context.tr('howInstantTitle'),
          lead: context.tr('howInstantText'),
        ),
      ),
      ImageRow(
        image: 'H05',
        imageRight: false,
        child: RowText(
          title: context.tr('howTranscribeTitle'),
          lead: context.tr('howTranscribeText'),
        ),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('howWhereTitle')),
          CardLine(
            cards: [
              LandingCard(
                image: 'H06',
                title: context.tr('howLocalTitle'),
                text: context.tr('howLocalText'),
              ),
              LandingCard(
                image: 'H07',
                title: context.tr('howSyncTitle'),
                text: context.tr('howSyncText'),
              ),
              LandingCard(
                image: 'H08',
                title: context.tr('howPublicTitle'),
                text: context.tr('howPublicText'),
              ),
            ],
          ),
        ],
      ),
      const TrainingNotice(),
      Column(
        key: const Key('faq'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(context.tr('faqTitle')),
          for (final (question, answer) in faq)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.colors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(question),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Text(
                      context.tr(answer),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ],
  );
}
