import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/landing_settings.dart';
import '../../components/interactive_card.dart';
import '../../components/landing_image.dart';
import '../../components/sketch_art.dart';
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

/// A row: text and one visual side by side. On a phone the text comes
/// first and the visual below it, at full width.
class VisualRow extends StatelessWidget {
  const VisualRow({
    super.key,
    required this.visual,
    required this.visualRight,
    required this.child,
    this.rowKey,
  });

  final Widget visual;
  final bool visualRight;
  final Widget child;
  final Key? rowKey;

  @override
  Widget build(BuildContext context) {
    if (isPhone(context)) {
      return Column(
        key: rowKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [child, const SizedBox(height: 24), visual],
      );
    }
    final side = Expanded(child: visual);
    final text = Expanded(child: child);
    return Row(
      key: rowKey,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: visualRight
          ? [text, const SizedBox(width: 56), side]
          : [side, const SizedBox(width: 56), text],
    );
  }
}

/// A row with one of the allowed photos (H6 slot id).
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
  Widget build(BuildContext context) => VisualRow(
    rowKey: Key('row-$image-${imageRight ? 'right' : 'left'}'),
    visual: LandingPicture(image),
    visualRight: imageRight,
    child: child,
  );
}

/// A link in running text: purple in light mode, green in dark mode, with
/// hover, focus and pressed states.
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
    AppLink(label: label, onTap: () => launchUrl(Uri.parse(url))),
  );
}

/// The training notice with the Terms and Privacy links (D8): a text card
/// with its icon tile, no photo.
class TrainingNotice extends StatelessWidget {
  const TrainingNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return Container(
      key: const Key('training-notice'),
      padding: EdgeInsets.all(isPhone(context) ? 20 : 32),
      decoration: BoxDecoration(
        color: c.subtle,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(SketchGlyph.notice, fill: AppPalette.orange),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    context.tr('noticeTitle'),
                    style: text.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
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
                          Text(
                            context.tr('noticeRead'),
                            style: text.bodyMedium,
                          ),
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
            ),
          ),
        ],
      ),
    );
  }
}

/// The page's one strong action at the end of a page, with a short lead.
class PageAction extends StatelessWidget {
  const PageAction({super.key, required this.lead, required this.button});

  final String lead;
  final Widget button;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(lead, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      button,
    ],
  );
}
