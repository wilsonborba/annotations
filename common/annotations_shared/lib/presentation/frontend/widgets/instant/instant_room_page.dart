/// The Instant room at /v1/instant/{code} (annotations#44): the shared paper
/// editor, the room code with Copy link, the remaining time with a warning
/// near the expiry, the sharing state (Connecting, Sharing, Shared,
/// Connection lost with Try again), refused text to review or copy, and at
/// the expiry the S02 picture with "This room has expired". There is no Undo
/// or Redo: the Instant editor has no history.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/features.dart';
import '../../../../core/platform_profile.dart';
import '../../../../core/tracking.dart';
import '../../../../core/tracking_manifest.dart';
import '../../../../dal/local/read_path.dart';
import '../../../../domain/services/instant_room_service.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/landing_image.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/instant_room_handler.dart';
import '../paper/paper_screen.dart';

class InstantRoomPage extends StatefulWidget {
  final String code;
  const InstantRoomPage({super.key, required this.code});

  /// Phones get simple typed controls; the browser gets them on a phone
  /// sized screen and the full editor otherwise (A2 matrix, Instant rows).
  static bool typedOnly(BuildContext context) =>
      switch (AppFeatures.profile ?? PlatformProfile.browser) {
        PlatformProfile.phone => true,
        PlatformProfile.fullWriter => false,
        PlatformProfile.browser =>
          MediaQuery.sizeOf(context).shortestSide < androidTabletShortestSideDp,
      };

  @override
  State<InstantRoomPage> createState() => _InstantRoomPageState();
}

class _InstantRoomPageState extends State<InstantRoomPage> {
  InstantRoomHandler? handler;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (handler == null) {
      handler = InstantRoomHandler(
        AppScope.of(context).service.api,
        widget.code,
        readPath: readPath,
      );
      handler!.open();
    }
  }

  @override
  void dispose() {
    handler?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: handler!,
    builder: (context, _) => _body(context, handler!),
  );

  Widget _body(BuildContext context, InstantRoomHandler h) {
    if (h.opening) {
      return const Center(child: CircularProgressIndicator());
    }
    if (h.expired) return const RoomExpiredView();
    final paper = h.paper;
    if (paper == null) {
      return LoadError(
        reference: ClientErrors.referenceOf(h.error),
        retry: h.open,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoomHeader(code: widget.code, handler: h),
        if (h.conflicts.isNotEmpty) RoomConflicts(handler: h),
        Expanded(
          child: PaperScreen(
            handler: paper,
            typedOnly: InstantRoomPage.typedOnly(context),
            status: RoomStatus(state: h.sharing, onRetry: h.retry),
          ),
        ),
      ],
    );
  }
}

/// The room code, Copy link and the remaining time. Near the expiry the
/// time shows as a warning with "This room expires soon" (C1.1).
class RoomHeader extends StatelessWidget {
  final String code;
  final InstantRoomHandler handler;
  const RoomHeader({super.key, required this.code, required this.handler});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final left = handler.remaining.inSeconds;
    final time = '${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
    final soon = handler.nearExpiry;
    return Container(
      key: const Key('room-header'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconButton(
                key: const Key('room-back'),
                icon: AppIcons.chevronLeft,
                label: context.tr('openRoom'),
                onPressed: () => context.go('/v1/instant'),
              ),
              const SizedBox(width: 4),
              AppIcon(AppIcons.peopleGroup, color: c.icon),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  code,
                  key: const Key('room-code'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 12),
              track(
                'instant.room.copy',
                AppButton(
                  key: const Key('room-copy'),
                  label: context.tr('copy'),
                  icon: AppIcons.link,
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: Uri.base
                            .replace(path: '/v1/instant/$code', query: '')
                            .toString(),
                      ),
                    );
                    if (context.mounted) {
                      showAppToast(context, context.tr('copied'));
                    }
                  },
                ),
              ),
            ],
          ),
          Semantics(
            liveRegion: soon,
            child: Row(
              key: Key(soon ? 'room-time-warning' : 'room-time'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (soon)
                  // A warning is a mark with a dark icon, as the save state.
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.warning,
                      borderRadius: BorderRadius.circular(appRadius),
                    ),
                    child: AppIcon(
                      AppIcons.clock,
                      size: 16,
                      color: c.onWarning,
                    ),
                  )
                else
                  AppIcon(AppIcons.clock, size: 18, color: c.iconSecondary),
                const SizedBox(width: 8),
                Text(time, style: Theme.of(context).textTheme.labelLarge),
                if (soon) ...[
                  const SizedBox(width: 8),
                  Text(context.tr('roomExpiresSoon')),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Connecting, Sharing, Shared, or Connection lost with Try again (C1.4).
class RoomStatus extends StatelessWidget {
  final InstantSharingState state;
  final VoidCallback onRetry;
  const RoomStatus({super.key, required this.state, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lost = state == InstantSharingState.connectionLost;
    final (icon, label) = switch (state) {
      InstantSharingState.connecting => (AppIcons.clock, 'roomConnecting'),
      InstantSharingState.sharing => (AppIcons.clock, 'roomSharing'),
      InstantSharingState.shared => (AppIcons.checkmarkCircle, 'roomShared'),
      InstantSharingState.connectionLost => (
        AppIcons.alertDiamond,
        'roomConnectionLost',
      ),
      InstantSharingState.expired => (AppIcons.clock, 'roomHasExpired'),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        key: Key('room-state-${state.name}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lost)
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.danger,
                borderRadius: BorderRadius.circular(appRadius),
              ),
              child: AppIcon(icon, size: 16, color: c.onDanger),
            )
          else
            AppIcon(icon, size: 18, color: c.iconSecondary),
          const SizedBox(width: 8),
          Text(
            context.tr(label),
            style: Theme.of(context).textTheme.labelMedium!.copyWith(
              color: lost ? c.text : c.textSecondary,
            ),
          ),
          if (lost) ...[
            const SizedBox(width: 8),
            AppButton(
              key: const Key('room-retry'),
              label: context.tr('retry'),
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

/// Text that the server refused because someone changed the same block
/// first (C1.5): kept here to read or copy until it is closed.
class RoomConflicts extends StatelessWidget {
  final InstantRoomHandler handler;
  const RoomConflicts({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const Key('room-conflicts'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.subtle,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(context.tr('roomRefused'))),
              AppButton(
                key: const Key('room-conflicts-close'),
                label: context.tr('close'),
                onPressed: handler.dismissConflicts,
              ),
            ],
          ),
          for (final (i, conflict) in handler.conflicts.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      conflict.text ?? '',
                      key: Key('room-conflict-$i'),
                    ),
                  ),
                  AppButton(
                    label: context.tr('copyText'),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: conflict.text ?? ''),
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

/// The expired room (C1.7): the S02 picture and "This room has expired".
/// The content is gone from the editor; nothing extends or saves the room.
class RoomExpiredView extends StatelessWidget {
  const RoomExpiredView({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const StatePicture('S02'),
          const SizedBox(height: 12),
          Text(
            context.tr('roomHasExpired'),
            key: const Key('room-expired'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 18),
          track(
            'instant.room.reopen',
            AppButton(
              label: context.tr('openRoom'),
              onPressed: () => context.go('/v1/instant'),
            ),
          ),
        ],
      ),
    ),
  );
}
