import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/installed_account.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';

/// `/v1/sign-in` in an installed app (annotations#38 scope 2): start the
/// browser login, compare the match code, press Finish. The messages come
/// from the FINAL record through NativeAuthService.
class InstalledSignInPage extends StatelessWidget {
  const InstalledSignInPage({super.key});

  @override
  Widget build(BuildContext context) {
    final account = AppScope.of(context).installed;
    if (account == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _body(context, account),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, InstalledAccount account) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    final back = track(
      'account.installed.back',
      AppButton.subtle(
        key: const Key('sign-in-back'),
        label: context.tr('backToNotes'),
        onPressed: () => context.go('/v1/write'),
      ),
    );
    if (account.signedIn) {
      return Column(
        key: const Key('sign-in-done'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.tr('signedInAs'), style: text.titleMedium),
          Text(account.email, style: text.headlineSmall),
          if (account.notice != null) ...[
            const SizedBox(height: 8),
            Text(
              noticeText(context, account.notice!),
              key: const Key('sign-in-message'),
              style: text.bodyMedium,
            ),
          ],
          const SizedBox(height: 24),
          back,
        ],
      );
    }
    final code = account.matchCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr('signIn'), style: text.headlineMedium),
        const SizedBox(height: 12),
        Text(
          context.tr(code == null ? 'installedSignInText' : 'matchCodeText'),
          style: text.bodyLarge!.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 24),
        if (code != null) ...[
          Container(
            key: const Key('match-code'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: c.selection,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.selectionOutline),
            ),
            child: Text(
              code,
              style: text.displaySmall!.copyWith(
                color: c.onSelection,
                letterSpacing: 6,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (account.notice != null) ...[
            const SizedBox(height: 16),
            Text(
              noticeText(context, account.notice!),
              key: const Key('sign-in-message'),
              style: text.bodyMedium,
            ),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              track(
                'account.installed.finish',
                AppButton.primary(
                  key: const Key('sign-in-finish'),
                  label: context.tr('finishLogin'),
                  onPressed: account.finishing ? null : account.finish,
                ),
              ),
              track(
                'account.installed.reopen',
                AppButton(
                  key: const Key('sign-in-reopen'),
                  label: context.tr('openBrowserAgain'),
                  onPressed: account.startLogin,
                ),
              ),
              track(
                'account.installed.cancel',
                AppButton.subtle(
                  key: const Key('sign-in-cancel'),
                  label: context.tr('cancel'),
                  onPressed: account.cancel,
                ),
              ),
            ],
          ),
        ] else ...[
          if (account.notice != null) ...[
            Text(
              noticeText(context, account.notice!),
              key: const Key('sign-in-message'),
              style: text.bodyMedium,
            ),
            const SizedBox(height: 16),
          ],
          track(
            'account.installed.start',
            AppButton.primary(
              key: const Key('sign-in-start'),
              label: context.tr('openBrowserLogin'),
              onPressed: account.startLogin,
            ),
          ),
          const SizedBox(height: 12),
          back,
        ],
      ],
    );
  }
}

/// The login message in the interface language, from its stable kind; the
/// city and country come from the FINAL record as they are.
String noticeText(BuildContext context, LoginNotice notice) {
  final place = [?notice.city, ?notice.country].join(', ');
  return switch (notice.kind) {
    LoginNoticeKind.success when place.isNotEmpty =>
      '${context.tr('loginSuccessFrom')} $place',
    LoginNoticeKind.success => context.tr('loginSuccess'),
    LoginNoticeKind.unavailable => context.tr('loginUnavailable'),
    LoginNoticeKind.notFinished => context.tr('loginNotFinished'),
    LoginNoticeKind.expired => context.tr('loginExpired'),
    LoginNoticeKind.used => context.tr('loginUsed'),
    LoginNoticeKind.cancelled => context.tr('loginCancelled'),
    LoginNoticeKind.refused => context.tr('loginRefused'),
    LoginNoticeKind.invalid => context.tr('loginInvalid'),
    LoginNoticeKind.disabled => context.tr('loginDisabled'),
    LoginNoticeKind.failed => context.tr('loginFailed'),
  };
}
