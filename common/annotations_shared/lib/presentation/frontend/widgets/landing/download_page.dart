import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/landing_settings.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import 'landing_blocks.dart';
import 'landing_sections.dart';

/// Download, /v1/home/download (H6 section 3 point 9, owner direction
/// 2026-11-20): the install block of every platform with its status, its
/// steps and its copy command, the public source and the update steps.
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key, this.releases = LandingSettings.releases});

  final Map<DownloadPlatform, PlatformRelease> releases;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LandingBody(
      children: [
        RowText(
          page: true,
          title: context.tr('downloadTitle'),
          lead: context.tr('downloadLead'),
          children: [
            Text(context.tr('downloadSource'), style: text.bodyMedium),
          ],
        ),
        InstallGrid(releases: releases, detailed: true),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(context.tr('sourceCommand')),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: CommandBox(
                key: const Key('source-command'),
                title: context.tr('repoLink'),
                command: LandingSettings.cloneCommand,
              ),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle(
              context.tr('updateTitle'),
              lead: context.tr('updateText'),
            ),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                TextLink(
                  key: const Key('releases-page'),
                  label: context.tr('releasesPage'),
                  url: LandingSettings.releasesPage,
                  trackId: 'download.releases.open',
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
        ),
      ],
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
