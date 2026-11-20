import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/landing_settings.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import 'landing_blocks.dart';

/// Download, /v1/home/download (H6 section 3 point 9): one card per
/// platform with its status; a released card also shows the version, the
/// date and the checksum. Mac and Linux keep the copy commands.
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key, this.releases = LandingSettings.releases});

  final Map<DownloadPlatform, PlatformRelease> releases;

  @override
  Widget build(BuildContext context) {
    PlatformRelease of(DownloadPlatform p) =>
        releases[p] ?? const PlatformRelease();
    final text = Theme.of(context).textTheme;
    return LandingBody(
      children: [
        ImageRow(
          image: 'D01',
          imageRight: true,
          child: RowText(
            page: true,
            title: context.tr('downloadTitle'),
            lead: context.tr('downloadLead'),
            children: [
              Text(context.tr('downloadSource'), style: text.bodyMedium),
            ],
          ),
        ),
        ImageRow(
          image: 'D02',
          imageRight: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final platform in const [
                DownloadPlatform.mac,
                DownloadPlatform.linux,
              ]) ...[
                PlatformCard(
                  platform: platform,
                  release: of(platform),
                  children: [
                    if (of(platform).installCommand != null)
                      CommandBox(
                        title: context.tr('installCommand'),
                        command: of(platform).installCommand!,
                        platform: platform,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              CommandBox(
                key: const Key('source-command'),
                title: context.tr('sourceCommand'),
                command: LandingSettings.cloneCommand,
              ),
            ],
          ),
        ),
        PlatformCard(
          platform: DownloadPlatform.android,
          release: of(DownloadPlatform.android),
          children: [
            Text(context.tr('androidStepsTitle'), style: text.titleSmall),
            for (final (i, step) in const [
              'androidStep1',
              'androidStep2',
              'androidStep3',
            ].indexed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${i + 1}. ${context.tr(step)}',
                  style: text.bodyMedium,
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextLink(
                key: const Key('releases-page'),
                label: context.tr('releasesPage'),
                url: LandingSettings.releasesPage,
                trackId: 'download.releases.open',
              ),
            ),
          ],
        ),
        ImageRow(
          image: 'D03',
          imageRight: true,
          child: PlatformCard(
            platform: DownloadPlatform.iosIpados,
            release: of(DownloadPlatform.iosIpados),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              context.tr('updateTitle'),
              lead: context.tr('updateText'),
            ),
            TextLink(
              key: const Key('download-repo'),
              label: context.tr('repoLink'),
              url: LandingSettings.app.url,
              trackId: 'download.repo.open',
            ),
          ],
        ),
      ],
    );
  }
}

/// One platform: its name, its status and, when released, the version, the
/// date and the checksum.
class PlatformCard extends StatelessWidget {
  const PlatformCard({
    super.key,
    required this.platform,
    required this.release,
    this.children = const [],
  });

  final DownloadPlatform platform;
  final PlatformRelease release;
  final List<Widget> children;

  static const names = {
    DownloadPlatform.mac: 'platformMac',
    DownloadPlatform.linux: 'platformLinux',
    DownloadPlatform.android: 'platformAndroid',
    DownloadPlatform.iosIpados: 'platformIos',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    // iPhone and iPad are not available to the public yet (X1).
    final status = platform == DownloadPlatform.iosIpados
        ? 'statusIos'
        : release.released
        ? 'statusReleased'
        : 'statusNoRelease';
    return Container(
      key: Key('platform-${platform.name}'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr(names[platform]!), style: text.titleLarge),
          const SizedBox(height: 6),
          Text(
            context.tr(status),
            key: Key('status-${platform.name}'),
            style: text.bodyMedium!.copyWith(color: c.textSecondary),
          ),
          if (release.released) ...[
            const SizedBox(height: 10),
            for (final (label, value) in [
              ('releaseVersion', release.version),
              ('releaseDate', release.date),
              ('releaseChecksum', release.checksum),
            ])
              if (value != null)
                SelectableText(
                  '${context.tr(label)}: $value',
                  style: text.bodySmall,
                ),
          ],
          for (final child in children) ...[const SizedBox(height: 14), child],
        ],
      ),
    );
  }
}

/// A command with its Copy button (the Parallax install cards).
class CommandBox extends StatelessWidget {
  const CommandBox({
    super.key,
    required this.title,
    required this.command,
    this.platform,
  });

  final String title;
  final String command;
  final DownloadPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: text.titleSmall),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          decoration: BoxDecoration(
            color: c.subtle,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Expanded(child: SelectableText(command, style: text.bodyMedium)),
              track(
                'download.command.copy',
                AppIconButton(
                  icon: AppIcons.copy,
                  label: context.tr('copyCommand'),
                  onPressed: () async {
                    trackChoice(
                      context,
                      'download.command.copy',
                      platform?.name ?? 'source',
                    );
                    await Clipboard.setData(ClipboardData(text: command));
                    if (context.mounted) {
                      showAppToast(context, context.tr('commandCopied'));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
