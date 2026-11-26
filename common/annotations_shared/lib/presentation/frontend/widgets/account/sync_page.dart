import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/account_service.dart';
import '../../components/account_menu.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';

/// `/sync`: auth_apps comes back here with the one-time token. The page
/// redeems it once, removes it from the address, and opens the kept page.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.token, this.onAddress});

  final String token;

  /// Replaces the browser address (the token must not stay in it).
  final void Function(String path)? onAddress;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _redeem();
  }

  Future<void> _redeem() async {
    widget.onAddress?.call(AccountService.syncPath);
    final account = AppScope.of(context).account;
    final ok =
        account != null &&
        widget.token.isNotEmpty &&
        await account.exchange(widget.token);
    if (!mounted) return;
    if (ok) {
      final next = await takeAfterLogin();
      if (mounted) context.go(next);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_failed) ...[
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Text(
                context.tr('signingIn'),
                key: const Key('sync-progress'),
                style: text.titleMedium,
              ),
            ] else ...[
              Text(
                context.tr('signInFailed'),
                key: const Key('sync-failed'),
                textAlign: TextAlign.center,
                style: text.titleMedium!.copyWith(color: context.colors.text),
              ),
              const SizedBox(height: 20),
              track(
                'account.sync.retry',
                AppButton.primary(
                  key: const Key('sync-retry'),
                  label: context.tr('retry'),
                  onPressed: () => signInOrOpen(
                    context,
                    returnTo: AccountService.myNotesPath,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
