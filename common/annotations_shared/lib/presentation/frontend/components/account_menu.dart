import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/tracking_manifest.dart';
import '../../../domain/services/account_service.dart';
import 'controls.dart';
import 'icons.dart';
import 'scope.dart';
import 'tokens.dart';

/// The page to open after the login, kept across the auth_apps round trip.
const afterLoginKey = 'annotations.after_login';

Future<void> keepAfterLogin(String path) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(afterLoginKey, path);
  } catch (_) {}
}

/// Reads the page kept by [keepAfterLogin] once.
Future<String> takeAfterLogin() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final next = prefs.getString(afterLoginKey);
    await prefs.remove(afterLoginKey);
    return AccountService.safeNext(next);
  } catch (_) {
    return AccountService.myNotesPath;
  }
}

/// Starts the login, or, when signed in, opens [signedInPath] instead: no
/// action ever asks a signed-in user to sign in again (Cortex #75).
void signInOrOpen(BuildContext context, {String? returnTo}) {
  final account = AppScope.of(context).account;
  if (account == null) return;
  if (account.signedIn) {
    context.go(AccountService.safeNext(returnTo));
    return;
  }
  account.signIn(returnTo: returnTo, keepNext: keepAfterLogin);
}

/// The account control of the top bar (H6 section 3 point 2): Sign in when
/// signed out; the avatar with the email, My notes and Log out when signed
/// in. While the live check runs it keeps its place and shows nothing, so
/// a signed-in user never sees Sign in flash.
class AccountControl extends StatelessWidget {
  const AccountControl({
    super.key,
    required this.location,
    this.compact = false,
  });

  /// The current page, to come back to after the login.
  final String location;

  /// On a phone the bar has no room for the Sign in button: it is the
  /// first row of the bar menu instead ([accountMenuEntries]).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final account = AppScope.of(context).account;
    if (account == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) => switch (account.status) {
        AccountStatus.checking => const SizedBox(
          key: Key('account-checking'),
          width: 36,
          height: 36,
        ),
        AccountStatus.signedOut when compact => const SizedBox.shrink(),
        AccountStatus.signedOut => track(
          'shell.account.sign_in',
          AppButton.subtle(
            key: const Key('bar-sign-in'),
            label: context.tr('signIn'),
            onPressed: () => signInOrOpen(
              context,
              returnTo: location.startsWith('/v1/') ? location : null,
            ),
          ),
        ),
        AccountStatus.signedIn => _AccountMenu(account: account),
      },
    );
  }
}

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.account});

  final AccountService account;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = account.name.isNotEmpty ? account.name : account.email;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        Padding(
          key: const Key('account-email'),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (account.name.isNotEmpty)
                Text(
                  account.name,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              Text(
                account.email,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        track(
          'shell.account.my_notes',
          MenuItemButton(
            key: const Key('account-my-notes'),
            requestFocusOnHover: false,
            leadingIcon: const AppIcon(AppIcons.fileText, size: 18),
            onPressed: () => context.go(AccountService.myNotesPath),
            child: Text(context.tr('myNotes')),
          ),
        ),
        track(
          'shell.account.log_out',
          MenuItemButton(
            key: const Key('account-log-out'),
            requestFocusOnHover: false,
            onPressed: () async {
              final router = GoRouter.of(context);
              final here = router.state.uri.path;
              await account.logOut();
              // A private page has nothing to show signed out.
              if (here.startsWith('/v1/me')) router.go('/v1/home');
            },
            child: Text(context.tr('logOut')),
          ),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: '${context.tr('account')}: $label',
        child: Semantics(
          button: true,
          label: '${context.tr('account')}: $label',
          child: AccountAvatar(
            key: const Key('account-avatar'),
            letter: label.isEmpty ? '?' : label.characters.first.toUpperCase(),
            open: controller.isOpen,
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ),
    );
  }
}

/// The round account avatar with hover, focus and pressed states: purple
/// fill with white text, the H7 main-action pair.
class AccountAvatar extends StatefulWidget {
  const AccountAvatar({
    super.key,
    required this.letter,
    required this.open,
    required this.onTap,
  });

  final String letter;
  final bool open;
  final VoidCallback onTap;

  @override
  State<AccountAvatar> createState() => _AvatarState();
}

class _AvatarState extends State<AccountAvatar> {
  bool _hover = false, _focus = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ring = _focus || widget.open;
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? .94 : 1,
          duration: const Duration(milliseconds: 90),
          child: Container(
            key: const Key('account-avatar-circle'),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? Color.lerp(c.accent, c.text, .15) : c.accent,
              border: Border.all(
                color: ring ? c.selectionOutline : Colors.transparent,
                width: 2,
              ),
            ),
            child: Text(
              widget.letter,
              style: TextStyle(
                color: c.onAccent,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Sign in row of the bar menu on a phone, when signed out.
List<AppMenuEntry> accountMenuEntries(BuildContext context, String location) {
  final account = AppScope.of(context).account;
  if (account == null || account.status != AccountStatus.signedOut) {
    return const [];
  }
  return [
    AppMenuEntry(
      key: const Key('menu-sign-in'),
      label: context.tr('signIn'),
      onSelected: () {
        trackChoice(context, 'shell.account.sign_in', 'menu');
        signInOrOpen(
          context,
          returnTo: location.startsWith('/v1/') ? location : null,
        );
      },
    ),
  ];
}
