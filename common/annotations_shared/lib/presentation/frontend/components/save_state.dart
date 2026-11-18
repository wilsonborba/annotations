import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../domain/services/note_autosave.dart';
import 'controls.dart';
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

/// The save state of the open note (B1.2): Saving, Saved, or Not saved with
/// Retry. It shows what the autosave service reports: Saved appears only
/// after the store committed the latest edit.
class SaveStateIndicator extends StatelessWidget {
  final ValueListenable<SaveState> state;
  final VoidCallback onRetry;
  const SaveStateIndicator({
    super.key,
    required this.state,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: state,
    builder: (context, value, _) =>
        SaveStateView(state: value, onRetry: onRetry),
  );
}

/// One save state, drawn without a listener (gallery and goldens).
class SaveStateView extends StatelessWidget {
  final SaveState state;
  final VoidCallback onRetry;
  const SaveStateView({super.key, required this.state, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final (icon, label) = switch (state) {
      SaveState.saving => (AppIcons.clock, context.tr('saveSaving')),
      SaveState.saved => (AppIcons.checkmarkCircle, context.tr('saveSaved')),
      SaveState.failed => (AppIcons.alertDiamond, context.tr('saveFailed')),
    };
    final failed = state == SaveState.failed;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        key: Key('save-state-${state.name}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failed)
            // Red is a mark with a dark icon, never light-mode text (H7 2.7).
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
            label,
            style: text.labelMedium!.copyWith(
              color: failed ? c.text : c.textSecondary,
            ),
          ),
          if (failed) ...[
            const SizedBox(width: 8),
            AppButton(
              key: const Key('save-retry'),
              label: context.tr('saveRetry'),
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}
