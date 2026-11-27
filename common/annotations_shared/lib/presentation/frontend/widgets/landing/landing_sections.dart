import 'dart:async';

import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/landing_settings.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/interactive_card.dart';
import '../../components/scope.dart';
import '../../components/sketch_art.dart';
import '../../components/sketch_pen.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import 'landing_blocks.dart';

/// The hero headline: Notion scale, with the key word marked by a pen that
/// draws a highlight under it and a loop around it, again and again
/// (owner direction 2026-11-20). Under reduced motion the marks stay still.
class AnimatedHeadline extends StatefulWidget {
  const AnimatedHeadline({super.key});

  @override
  State<AnimatedHeadline> createState() => _AnimatedHeadlineState();
}

/// The pen cycle point shown under reduced motion: both marks drawn.
const stillProgress = .7;

class _AnimatedHeadlineState extends State<AnimatedHeadline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _pen
        ..stop()
        ..value = stillProgress;
    } else if (!_pen.isAnimating) {
      _pen.repeat();
    }
  }

  @override
  void dispose() {
    _pen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final size = width < 600
        ? 40.0
        : width < 1000
        ? 52.0
        : 64.0;
    final style = Theme.of(context).textTheme.headlineLarge!.copyWith(
      fontSize: size,
      height: 1.1,
      letterSpacing: -size * .02,
    );
    final still = MediaQuery.of(context).disableAnimations;
    return Semantics(
      header: true,
      label:
          '${context.tr('heroBefore')}${context.tr('heroWord')}${context.tr('heroAfter')}',
      excludeSemantics: true,
      child: Text.rich(
        key: const Key('hero-headline'),
        TextSpan(
          style: style,
          children: [
            TextSpan(text: context.tr('heroBefore')),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: AnimatedBuilder(
                animation: _pen,
                builder: (context, child) => CustomPaint(
                  key: const Key('hero-word-marks'),
                  painter: _WordMarks(
                    progress: still ? stillProgress : _pen.value,
                    highlight: AppPalette.green,
                    loop: AppPalette.purple,
                  ),
                  child: child,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: size * .08),
                  child: Text(context.tr('heroWord'), style: style),
                ),
              ),
            ),
            TextSpan(text: context.tr('heroAfter')),
          ],
        ),
      ),
    );
  }
}

class _WordMarks extends CustomPainter {
  _WordMarks({
    required this.progress,
    required this.highlight,
    required this.loop,
  });

  /// 0 to 1 over one pen cycle: the highlight draws in the first third,
  /// the loop in the second, both rest, then fade.
  final double progress;
  final Color highlight, loop;

  @override
  void paint(Canvas canvas, Size size) {
    final draw = (progress / .33).clamp(0.0, 1.0);
    final circle = ((progress - .33) / .33).clamp(0.0, 1.0);
    final fade = progress > .9 ? 1 - (progress - .9) / .1 : 1.0;
    final y = size.height * .78;
    final h = Paint()
      ..color = highlight.withValues(alpha: .55 * fade)
      ..strokeWidth = size.height * .2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * .04, y),
      Offset(size.width * (.04 + .92 * draw), y - 2),
      h,
    );
    if (circle > 0) {
      final rect = Rect.fromLTWH(
        -size.width * .05,
        size.height * .04,
        size.width * 1.1,
        size.height * .96,
      );
      final path = Path()..addArc(rect, -2.6, 6.6 * circle);
      canvas.drawPath(
        path,
        penPaint(loop.withValues(alpha: fade), size.height * .045),
      );
    }
  }

  @override
  bool shouldRepaint(_WordMarks old) => old.progress != progress;
}

/// The product showcase (Linear and Obsidian): a desktop window of the app
/// with the phone stacked over its corner. It moves to the next platform
/// every few seconds, the user can choose one, and it waits while the
/// pointer or the focus is on it. Under reduced motion it never moves.
class ProductShowcase extends StatefulWidget {
  const ProductShowcase({
    super.key,
    this.interval = const Duration(seconds: 5),
  });

  final Duration interval;

  @override
  State<ProductShowcase> createState() => ProductShowcaseState();
}

class ProductShowcaseState extends State<ProductShowcase> {
  ShowcasePlatform platform = ShowcasePlatform.mac;
  Timer? _timer;
  bool _hover = false, _focus = false;

  bool get paused => _hover || _focus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (MediaQuery.of(context).disableAnimations) return;
    _timer = Timer.periodic(widget.interval, (_) {
      if (paused || !mounted) return;
      setState(() {
        platform = ShowcasePlatform
            .values[(platform.index + 1) % ShowcasePlatform.values.length];
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void choose(ShowcasePlatform next) {
    trackChoice(context, 'landing.showcase.select', next.name);
    setState(() => platform = next);
    _restart();
  }

  static const _labels = {
    ShowcasePlatform.mac: 'showMac',
    ShowcasePlatform.linux: 'showLinux',
    ShowcasePlatform.browser: 'showBrowser',
  };

  @override
  Widget build(BuildContext context) {
    final dark = context.colors.isDark;
    final phone = isPhone(context);
    final still = MediaQuery.of(context).disableAnimations;
    if (phone) {
      final scene = switch (platform) {
        ShowcasePlatform.mac => SketchScene.notes,
        ShowcasePlatform.linux => SketchScene.writing,
        ShowcasePlatform.browser => SketchScene.tasks,
      };
      return Semantics(
        label: context.tr('showcaseLabel'),
        container: true,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: AspectRatio(
              aspectRatio: 400 / 260,
              child: AnimatedSwitcher(
                duration: still
                    ? Duration.zero
                    : const Duration(milliseconds: 450),
                child: SketchArt(scene, key: ValueKey(scene)),
              ),
            ),
          ),
        ),
      );
    }
    final shot = platform == ShowcasePlatform.browser
        ? browserShot
        : desktopShot;
    final window = AppWindowFrame(
      key: ValueKey(platform),
      platform: platform,
      child: Image.asset(
        shot.asset(dark),
        package: 'annotations_shared',
        fit: BoxFit.cover,
        alignment: Alignment.topLeft,
        excludeFromSemantics: true,
        errorBuilder: (context, _, _) =>
            ColoredBox(color: context.colors.subtle),
      ),
    );
    return Semantics(
      label: context.tr('showcaseLabel'),
      container: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (v) => setState(() => _focus = v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Wrap(
                  key: const Key('showcase-switch'),
                  spacing: 6,
                  children: [
                    for (final p in ShowcasePlatform.values)
                      track(
                        'landing.showcase.select',
                        _ShowcaseTab(
                          key: Key('showcase-${p.name}'),
                          label: context.tr(_labels[p]!),
                          selected: p == platform,
                          onPressed: () => choose(p),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              LayoutBuilder(
                builder: (context, c) {
                  final phoneWidth = c.maxWidth * .2;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          right: phoneWidth * .55,
                          bottom: 56,
                        ),
                        child: AspectRatio(
                          aspectRatio: desktopShot.ratio * .94,
                          child: AnimatedSwitcher(
                            duration: still
                                ? Duration.zero
                                : const Duration(milliseconds: 350),
                            child: window,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        width: phoneWidth,
                        child: PhoneFrame(
                          child: Image.asset(
                            phoneShot.asset(dark),
                            package: 'annotations_shared',
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            excludeFromSemantics: true,
                            errorBuilder: (context, _, _) =>
                                ColoredBox(color: context.colors.subtle),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A platform choice of the showcase: green fill with dark text when
/// chosen (H7 selection), a quiet text button otherwise.
class _ShowcaseTab extends StatelessWidget {
  const _ShowcaseTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: TextButton(
        onPressed: onPressed,
        style:
            appButtonStyle(
              c,
              Theme.of(context).textTheme,
              AppButtonKind.subtle,
            ).copyWith(
              backgroundColor: selected
                  ? WidgetStatePropertyAll(c.selection)
                  : null,
              foregroundColor: selected
                  ? WidgetStatePropertyAll(c.onSelection)
                  : null,
              side: selected && !c.isDark
                  ? WidgetStatePropertyAll(
                      BorderSide(color: c.selectionOutline),
                    )
                  : null,
            ),
        child: Text(label),
      ),
    );
  }
}

/// A clean window frame: the macOS title bar with its three dots, a Linux
/// title bar with its controls on the right, or a browser with the address.
class AppWindowFrame extends StatelessWidget {
  const AppWindowFrame({
    super.key,
    required this.platform,
    required this.child,
  });

  final ShowcasePlatform platform;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bar = c.isDark ? const Color(0xFF22242C) : const Color(0xFFEDEDF0);
    Widget dot(Color color) => Container(
      width: 11,
      height: 11,
      margin: const EdgeInsets.only(right: 7),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    final title = Text(
      'Annotations',
      style: Theme.of(
        context,
      ).textTheme.labelMedium!.copyWith(color: c.textSecondary),
    );
    final top = switch (platform) {
      ShowcasePlatform.mac => Row(
        children: [
          dot(const Color(0xFFFF5F57)),
          dot(const Color(0xFFFEBC2E)),
          dot(const Color(0xFF28C840)),
          const Spacer(),
          title,
          const Spacer(),
          const SizedBox(width: 54),
        ],
      ),
      ShowcasePlatform.linux => Row(
        children: [
          title,
          const Spacer(),
          for (final glyph in const ['_', '\u25A1', '\u00D7'])
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(glyph, style: TextStyle(color: c.textSecondary)),
            ),
        ],
      ),
      ShowcasePlatform.browser => Row(
        children: [
          dot(c.control),
          dot(c.control),
          dot(c.control),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                'annotations.asodya.com',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall!.copyWith(color: c.textSecondary),
              ),
            ),
          ),
        ],
      ),
    };
    return Container(
      key: Key('window-${platform.name}'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            offset: Offset(0, 18),
            blurRadius: 40,
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            color: bar,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: top,
          ),
          Expanded(
            child: SizedBox(width: double.infinity, child: child),
          ),
        ],
      ),
    );
  }
}

/// A phone outline around the phone screenshot.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: phoneShot.ratio,
    child: Container(
      key: const Key('phone-frame'),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF15171D),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF3A3C46), width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            offset: Offset(0, 16),
            blurRadius: 36,
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(20), child: child),
    ),
  );
}

/// The install section (Obsidian layout): one block per platform with its
/// icon, what it does there, its status, a Download or Open action, a copy
/// command where one exists and the way to the install steps.
class InstallGrid extends StatelessWidget {
  const InstallGrid({
    super.key,
    this.releases = LandingSettings.releases,
    this.detailed = false,
  });

  final Map<DownloadPlatform, PlatformRelease> releases;

  /// On the Download page the steps show inline instead of the link, and
  /// opening the browser app is the page's one strong action.
  final bool detailed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final columns = c.maxWidth >= 900
          ? 3
          : c.maxWidth >= 560
          ? 2
          : 1;
      final width = (c.maxWidth - (columns - 1) * 16) / columns;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final p in InstallPlatform.values)
                SizedBox(
                  width: width,
                  child: InstallBlock(
                    platform: p,
                    releases: releases,
                    detailed: detailed,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('installSeparately'),
            key: const Key('install-note'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    },
  );
}

class InstallBlock extends StatelessWidget {
  const InstallBlock({
    super.key,
    required this.platform,
    required this.releases,
    this.detailed = false,
  });

  final InstallPlatform platform;
  final Map<DownloadPlatform, PlatformRelease> releases;
  final bool detailed;

  static const glyphs = {
    InstallPlatform.mac: SketchGlyph.laptop,
    InstallPlatform.linux: SketchGlyph.linux,
    InstallPlatform.tablets: SketchGlyph.tablet,
    InstallPlatform.androidPhones: SketchGlyph.phone,
    InstallPlatform.iphone: SketchGlyph.iphone,
    InstallPlatform.browser: SketchGlyph.browser,
  };

  static const names = {
    InstallPlatform.mac: 'platformMac',
    InstallPlatform.linux: 'platformLinux',
    InstallPlatform.tablets: 'platformTablets',
    InstallPlatform.androidPhones: 'platformAndroidPhones',
    InstallPlatform.iphone: 'platformIphone',
    InstallPlatform.browser: 'platformWeb',
  };

  /// What each platform does (accepted Overview wording).
  static const roles = {
    InstallPlatform.mac: 'platformWritersText',
    InstallPlatform.linux: 'platformWritersText',
    InstallPlatform.tablets: 'platformWritersText',
    InstallPlatform.androidPhones: 'platformPhonesText',
    InstallPlatform.iphone: 'platformPhonesText',
    InstallPlatform.browser: 'platformBrowserText',
  };

  /// The release that serves this block; iPhone, iPad and the browser
  /// have none.
  DownloadPlatform? get release => switch (platform) {
    InstallPlatform.mac => DownloadPlatform.mac,
    InstallPlatform.linux => DownloadPlatform.linux,
    InstallPlatform.tablets ||
    InstallPlatform.androidPhones => DownloadPlatform.android,
    InstallPlatform.iphone || InstallPlatform.browser => null,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final info = release == null ? null : releases[release];
    final released = info?.released ?? false;
    final status = switch (platform) {
      InstallPlatform.browser => 'statusWeb',
      InstallPlatform.iphone => 'statusIos',
      _ => released ? 'statusReleased' : 'statusNoRelease',
    };
    final browser = platform == InstallPlatform.browser;
    final command = browser
        ? LandingSettings.siteAddress
        : info?.installCommand;
    final Widget action;
    if (browser && detailed) {
      action = AppButton.primary(
        key: Key('install-${platform.name}-action'),
        label: context.tr('actionOpenWeb'),
        onPressed: () => context.go('/v1/menu'),
      );
    } else if (browser) {
      action = AppButton(
        key: Key('install-${platform.name}-action'),
        label: context.tr('actionOpenWeb'),
        onPressed: () => context.go('/v1/menu'),
      );
    } else {
      action = AppButton(
        key: Key('install-${platform.name}-action'),
        label: context.tr('actionDownload'),
        onPressed: released
            ? () => launchUrl(Uri.parse(LandingSettings.releasesPage))
            : null,
      );
    }
    return Container(
      key: Key('install-${platform.name}'),
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
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.subtle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SketchIcon(glyphs[platform]!, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.tr(names[platform]!),
                  style: text.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(context.tr(roles[platform]!), style: text.bodyMedium),
          const SizedBox(height: 4),
          Text(
            context.tr(status),
            key: Key('install-${platform.name}-status'),
            style: text.bodySmall,
          ),
          if (released) ...[
            const SizedBox(height: 4),
            Text(
              '${context.tr('releaseVersion')} ${info!.version} · ${info.date}',
              style: text.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          track('landing.install.action', action),
          if (command != null) ...[
            const SizedBox(height: 12),
            CopyLine(
              key: Key('install-${platform.name}-copy'),
              text: command,
              label: context.tr(browser ? 'copyAddress' : 'copyCommand'),
              done: context.tr(browser ? 'addressCopied' : 'commandCopied'),
              value: platform.name,
            ),
          ],
          if (detailed && !browser && platform != InstallPlatform.iphone) ...[
            const SizedBox(height: 16),
            Text(context.tr('stepsTitle'), style: text.titleSmall),
            for (final (i, step) in (switch (platform) {
              InstallPlatform.tablets || InstallPlatform.androidPhones =>
                const ['androidStep1', 'androidStep2', 'androidStep3'],
              _ => const ['updateText'],
            }).indexed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${i + 1}. ${context.tr(step)}',
                  style: text.bodySmall,
                ),
              ),
          ] else if (!detailed && !browser) ...[
            const SizedBox(height: 10),
            AppLink(
              key: Key('install-${platform.name}-how'),
              label: context.tr('howToInstall'),
              trailing: true,
              onTap: () {
                trackChoice(context, 'landing.install.how', platform.name);
                context.go('/v1/home/download');
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// A command or address with its Copy button.
class CopyLine extends StatelessWidget {
  const CopyLine({
    super.key,
    required this.text,
    required this.label,
    required this.done,
    required this.value,
  });

  final String text, label, done, value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
      decoration: BoxDecoration(
        color: c.subtle,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              text,
              maxLines: 1,
              style: Theme.of(
                context,
              ).textTheme.bodySmall!.copyWith(color: c.text),
            ),
          ),
          track(
            'download.command.copy',
            AppIconButton(
              icon: AppIcons.copy,
              label: label,
              onPressed: () async {
                trackChoice(context, 'download.command.copy', value);
                await Clipboard.setData(ClipboardData(text: text));
                if (context.mounted) showAppToast(context, done);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A card with a drawn illustration above its title and text; the whole
/// card is one link (Linear feature cards, Notion illustrated cards).
class IllustratedCard extends StatelessWidget {
  const IllustratedCard({
    super.key,
    required this.scene,
    required this.title,
    required this.body,
    this.pair,
    this.onTap,
    this.trackId,
  });

  final SketchScene scene;
  final String title, body;
  final (Color, Color)? pair;
  final VoidCallback? onTap;
  final String? trackId;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final card = InteractiveCard(
      onTap: onTap,
      semanticLabel: title,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.colors.subtle,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SketchArt(scene, pair: pair),
          ),
          const SizedBox(height: 18),
          Text(title, style: text.titleLarge),
          const SizedBox(height: 8),
          Text(
            body,
            style: text.bodyMedium!.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
        ],
      ),
    );
    return trackId == null ? card : track(trackId!, card);
  }
}

/// Cards side by side on a wide window, one per line on a phone, all the
/// same height in a line.
class CardRow extends StatelessWidget {
  const CardRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            children[i],
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }
}
