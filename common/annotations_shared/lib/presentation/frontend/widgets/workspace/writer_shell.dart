import 'package:flutter/material.dart';

import '../../../../core/tracking_manifest.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';

/// The minimal bar of the installed writer (A2/F1 minimal UI; installed-app
/// rule: no browser landing): the brand, language and theme only.
class WriterShell extends StatelessWidget {
  const WriterShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final prefs = AppScope.of(context).preferences;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        key: const Key('writer-bar'),
        toolbarHeight: 64,
        titleSpacing: width > 740 ? 34 : 12,
        title: AppBrand(
          homeLabel: context.tr('workspaceTitle'),
          showTitle: width >= 430,
          onHome: () {},
        ),
        actions: [
          LanguageSwitch(selected: prefs.locale, onChanged: prefs.language),
          const SizedBox(width: 6),
          track(
            'shell.theme.toggle',
            AppIconButton.navigation(
              key: const Key('theme-toggle'),
              icon: AppIcons.contrast,
              label: context.tr('theme'),
              onPressed: () => prefs.toggle(dark),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(child: child),
    );
  }
}
