import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/landing_settings.dart';
import '../../components/landing_image.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/tokens.dart';

/// The content is 1200 px wide at most (H6 section 4 point 2).
const landingContentWidth = 1200.0;

/// "Phone" means a window under 600 px wide.
bool isPhone(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

double _gutter(BuildContext context) =>
    MediaQuery.sizeOf(context).width > 740 ? 32 : 20;

/// One landing page: its sections in a 1200 px column, one page per tab.
class LandingBody extends StatelessWidget {
  const LandingBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ContentWidth(
    width: landingContentWidth + 2 * _gutter(context),
    padding: EdgeInsets.fromLTRB(
      _gutter(context),
      isPhone(context) ? 32 : 56,
      _gutter(context),
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: isPhone(context) ? 48 : 72),
          children[i],
        ],
      ],
    ),
  );
}

/// The title of a section.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.lead});

  final String text;
  final String? lead;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.headlineMedium),
        ),
        if (lead != null) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(lead!, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ],
      ],
    ),
  );
}

/// The title, the lead and the parts of a page or a row, beside an image.
class RowText extends StatelessWidget {
  const RowText({
    super.key,
    required this.title,
    this.lead,
    this.children = const [],
    this.page = false,
  });

  final String title;
  final String? lead;
  final List<Widget> children;

  /// True for the page title: a larger heading.
  final bool page;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: page
                ? text.headlineLarge!.copyWith(
                    fontSize: isPhone(context) ? 34 : 46,
                  )
                : text.headlineSmall,
          ),
        ),
        if (lead != null) ...[
          SizedBox(height: page ? 20 : 12),
          Text(lead!, style: text.bodyLarge),
        ],
        for (final child in children) ...[const SizedBox(height: 16), child],
      ],
    );
  }
}

/// A row: text and one image side by side. On a phone the text comes first
/// and the image below it, at full width.
class ImageRow extends StatelessWidget {
  const ImageRow({
    super.key,
    required this.image,
    required this.imageRight,
    required this.child,
  });

  final String image;
  final bool imageRight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tall = landingImages[image]!.tall;
    if (isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          child,
          const SizedBox(height: 24),
          LandingPicture(image, maxWidth: tall ? 280 : null),
        ],
      );
    }
    final picture = tall
        ? SizedBox(width: 280, child: LandingPicture(image))
        : Expanded(child: LandingPicture(image));
    final text = Expanded(child: child);
    return Row(
      key: Key('row-$image-${imageRight ? 'right' : 'left'}'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: imageRight
          ? [text, const SizedBox(width: 48), picture]
          : [picture, const SizedBox(width: 48), text],
    );
  }
}

/// One card: the image above its title and text. A card with [onOpen] is
/// a link as a whole.
class LandingCard {
  const LandingCard({
    required this.image,
    required this.title,
    required this.text,
    this.trackId,
    this.onOpen,
  });

  final String image;
  final String title;
  final String text;
  final String? trackId;
  final VoidCallback? onOpen;
}

/// Cards of 2 or 3 in one line; one per line on a phone.
class CardLine extends StatelessWidget {
  const CardLine({super.key, required this.cards});

  final List<LandingCard> cards;

  @override
  Widget build(BuildContext context) {
    final items = [for (final card in cards) _Card(card)];
    if (isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 28),
            items[i],
          ],
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 20),
          Expanded(child: items[i]),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card(this.card);

  final LandingCard card;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final tall = landingImages[card.image]!.tall;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LandingPicture(card.image, maxWidth: tall ? 280 : null),
        const SizedBox(height: 16),
        Text(
          card.title,
          style: text.titleMedium!.copyWith(
            color: card.onOpen == null ? null : context.colors.link,
          ),
        ),
        const SizedBox(height: 6),
        Text(card.text, style: text.bodyMedium),
      ],
    );
    if (card.onOpen == null) return body;
    return track(
      card.trackId!,
      Semantics(
        link: true,
        child: InkWell(
          key: Key('card-${card.image}'),
          borderRadius: BorderRadius.circular(8),
          onTap: card.onOpen,
          child: body,
        ),
      ),
    );
  }
}

/// A link in running text: purple in light mode, green in dark mode.
class TextLink extends StatelessWidget {
  const TextLink({
    super.key,
    required this.label,
    required this.url,
    required this.trackId,
  });

  final String label;
  final String url;
  final String trackId;

  @override
  Widget build(BuildContext context) => track(
    trackId,
    Semantics(
      link: true,
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(url)),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium!.copyWith(
            color: context.colors.link,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: context.colors.link,
          ),
        ),
      ),
    ),
  );
}

/// The training notice with the Terms and Privacy links (D8). With
/// [band], the O10 band image shows above it.
class TrainingNotice extends StatelessWidget {
  const TrainingNotice({super.key, this.band = false});

  final bool band;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      key: const Key('training-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (band) ...[const LandingPicture('O10'), const SizedBox(height: 24)],
        Semantics(
          header: true,
          child: Text(context.tr('noticeTitle'), style: text.headlineSmall),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr('noticeText'), style: text.bodyLarge),
              const SizedBox(height: 8),
              Text(context.tr('noticePrivate'), style: text.bodyLarge),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  Text(context.tr('noticeRead'), style: text.bodyMedium),
                  TextLink(
                    key: const Key('notice-terms'),
                    label: context.tr('terms'),
                    url: LandingSettings.terms,
                    trackId: 'landing.notice.terms',
                  ),
                  Text(context.tr('and'), style: text.bodyMedium),
                  TextLink(
                    key: const Key('notice-privacy'),
                    label: context.tr('privacy'),
                    url: LandingSettings.privacy,
                    trackId: 'landing.notice.privacy',
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
