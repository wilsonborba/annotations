import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/landing_settings.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/sketch_art.dart';
import '../../components/sketch_diagram.dart';
import '../../components/tokens.dart';
import 'landing_blocks.dart';

/// How it works, /v1/home/how-it-works (H6 section 3 point 7, owner
/// direction 2026-11-20): text-led sections with drawn flows instead of
/// photos. Open Instant is the page's one strong action.
class HowItWorksPage extends StatelessWidget {
  const HowItWorksPage({super.key});

  static const faq = [
    ('faqLoginQ', 'faqLoginA'),
    ('faqSyncQ', 'faqSyncA'),
    ('faqInstantQ', 'faqInstantA'),
    ('faqBrowserQ', 'faqBrowserA'),
    ('faqTrainingQ', 'faqTrainingA'),
  ];

  static const noteFlow = <List<DiagramPart>>[
    [DiagramPart('diagramWrite')],
    [DiagramPart('diagramSignIn')],
    [DiagramPart('diagramPublish')],
  ];

  static const draftFlow = <List<DiagramPart>>[
    [DiagramPart('diagramDraft')],
    [DiagramPart('diagramReview')],
    [DiagramPart('diagramAccept')],
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    void none(PublicRepo _) {}
    Widget visual(SketchScene scene) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colors.subtle,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SketchArt(scene),
    );
    return LandingBody(
      children: [
        RowText(
          page: true,
          title: context.tr('howTitle'),
          lead: context.tr('overviewLead'),
        ),
        Column(
          key: const Key('how-note'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(context.tr('howNoteTitle')),
            SketchDiagram(name: 'note', stages: noteFlow, onOpen: none),
            const SizedBox(height: 28),
            _Steps(
              steps: const [
                (SketchGlyph.pen, 'howWriteTitle', 'howWriteText'),
                (SketchGlyph.key, 'howSignInTitle', 'howSignInText'),
                (SketchGlyph.board, 'howPublishTitle', 'howPublishText'),
              ],
            ),
          ],
        ),
        VisualRow(
          rowKey: const Key('how-instant'),
          visualRight: true,
          visual: visual(SketchScene.instant),
          child: RowText(
            title: context.tr('howInstantTitle'),
            lead: context.tr('howInstantText'),
            children: [
              track(
                'landing.instant.open',
                AppButton.primary(
                  key: const Key('how-open-instant'),
                  label: context.tr('actionInstant'),
                  onPressed: () => context.go('/v1/instant'),
                ),
              ),
            ],
          ),
        ),
        Column(
          key: const Key('how-transcribe'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              context.tr('howTranscribeTitle'),
              lead: context.tr('howTranscribeText'),
            ),
            SketchDiagram(name: 'draft', stages: draftFlow, onOpen: none),
          ],
        ),
        Column(
          key: const Key('how-where'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(context.tr('howWhereTitle')),
            _Steps(
              numbered: false,
              steps: const [
                (SketchGlyph.laptop, 'howLocalTitle', 'howLocalText'),
                (SketchGlyph.cloud, 'howSyncTitle', 'howSyncText'),
                (SketchGlyph.people, 'howPublicTitle', 'howPublicText'),
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
                    Text(context.tr(question), style: text.titleMedium),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Text(context.tr(answer), style: text.bodyMedium),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Three short text cards with a drawn icon, side by side on a wide
/// window.
class _Steps extends StatelessWidget {
  const _Steps({required this.steps, this.numbered = true});

  final List<(SketchGlyph, String, String)> steps;
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    final pairs = [
      (AppPalette.green, AppPalette.purple),
      AppPalette.pairs[1],
      AppPalette.pairs[3],
    ];
    final cards = [
      for (final (i, (glyph, title, body)) in steps.indexed)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconTile(glyph, fill: pairs[i % pairs.length].$1, size: 40),
                  if (numbered) ...[
                    const SizedBox(width: 12),
                    Text('${i + 1}', style: text.titleLarge),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              Text(context.tr(title), style: text.titleMedium),
              const SizedBox(height: 6),
              Text(
                context.tr(body),
                style: text.bodyMedium!.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
    ];
    if (isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            cards[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }
}
