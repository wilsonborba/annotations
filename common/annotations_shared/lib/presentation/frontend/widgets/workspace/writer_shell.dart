import 'package:flutter/material.dart';

import '../../../../core/tracking_manifest.dart';
import 'package:go_router/go_router.dart';

import '../../../../domain/services/account_service.dart' show AccountStatus;
import '../../components/account_menu.dart' show AccountAvatar;
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
          const SizedBox(width: 8),
          const InstalledAccountControl(),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(child: child),
    );
  }
}

/// The account of the writer bar: Sign in, or the avatar with the email
/// and Log out. Nothing shows while the live check runs.
class InstalledAccountControl extends StatelessWidget {
  const InstalledAccountControl({super.key});

  @override
  Widget build(BuildContext context) {
    final account = AppScope.of(context).installed;
    if (account == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => switch (account.status) {
        AccountStatus.checking => const SizedBox(
          key: Key('account-checking'),
          width: 36,
        ),
        AccountStatus.signedOut => track(
          'shell.account.sign_in',
          AppButton.subtle(
            key: const Key('bar-sign-in'),
            label: context.tr('signIn'),
            onPressed: () => context.go('/v1/sign-in'),
          ),
        ),
        AccountStatus.signedIn => MenuAnchor(
          alignmentOffset: const Offset(0, 6),
          menuChildren: [
            Padding(
              key: const Key('account-email'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Text(account.email),
            ),
            const Divider(height: 1),
            track(
              'shell.account.log_out',
              MenuItemButton(
                key: const Key('account-log-out'),
                requestFocusOnHover: false,
                onPressed: account.logOut,
                child: Text(context.tr('logOut')),
              ),
            ),
          ],
          builder: (context, controller, _) => Semantics(
            button: true,
            label: '${context.tr('account')}: ${account.email}',
            child: AccountAvatar(
              key: const Key('account-avatar'),
              letter: account.email.isEmpty
                  ? '?'
                  : account.email.characters.first.toUpperCase(),
              open: controller.isOpen,
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
        ),
      },
    );
  }
}
