import 'package:flutter/material.dart';
import 'icons.dart';
import 'theme.dart';
import 'tokens.dart';

/// The keyboard focus mark: a green ring with a darker outline on light
/// surfaces. It shows only while the keyboard moves the focus.
class FocusRing extends StatelessWidget {
  final bool visible;
  final double radius;
  final Widget child;
  const FocusRing({
    super.key,
    required this.visible,
    required this.child,
    this.radius = appRadius,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Borders only: the control under the ring stays visible.
    Color edge(Color color) => visible ? color : Colors.transparent;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + 4),
        border: Border.all(
          color: edge(c.isDark ? c.selection : c.selectionOutline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 3),
            border: Border.all(color: edge(c.selection), width: 2),
          ),
          child: Padding(padding: const EdgeInsets.all(3), child: child),
        ),
      ),
    );
  }
}

/// Tracks keyboard focus of a descendant control for the [FocusRing].
class _Focusable extends StatefulWidget {
  final double radius;
  final Widget child;
  const _Focusable({required this.child, this.radius = appRadius});
  @override
  State<_Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<_Focusable> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    onFocusChange: (value) => setState(
      () => focused =
          value &&
          FocusManager.instance.highlightMode == FocusHighlightMode.traditional,
    ),
    child: FocusRing(
      visible: focused,
      radius: widget.radius,
      child: widget.child,
    ),
  );
}

/// A button with a text label and an optional leading icon.
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppButtonKind kind;
  final AppIconData? icon;

  /// An icon after the label, for forward navigation.
  final AppIconData? trailingIcon;
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = AppButtonKind.secondary,
    this.icon,
    this.trailingIcon,
  });

  const AppButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
  }) : kind = AppButtonKind.primary;

  const AppButton.subtle({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
  }) : kind = AppButtonKind.subtle;

  const AppButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
  }) : kind = AppButtonKind.danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Focusable(
      child: TextButton(
        style: appButtonStyle(context.colors, theme.textTheme, kind),
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              AppIcon(icon!, size: 18),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(label)),
            if (trailingIcon != null) ...[
              const SizedBox(width: 8),
              AppIcon(trailingIcon!, size: 18),
            ],
          ],
        ),
      ),
    );
  }
}

/// The name of an icon control: on hover for a mouse or pen; on touch, which
/// has no hover, a long press shows it next to the finger without running
/// the control, and lifting the finger hides it (B7, annotations#31).
class AppTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  const AppTooltip({super.key, required this.message, required this.child});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: message,
    excludeFromSemantics: true,
    triggerMode: TooltipTriggerMode.longPress,
    showDuration: Duration.zero,
    child: child,
  );
}

/// A subtle icon button for a secondary action. The label is the tooltip
/// and the screen reader name. A disabled button has no tooltip.
///
/// [AppIconButton.navigation] is the round variant. Use it only in the top
/// navigation.
///
/// [selected] marks an active toggle (Bold on): a green fill with a dark
/// icon, as the active tool (H7 colors rule 3).
class AppIconButton extends StatelessWidget {
  final AppIconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool round;
  final double iconSize;
  final bool? selected;

  /// A red fill with a dark icon for an active dangerous mode (Delete
  /// anything on the eraser).
  final bool danger;
  const AppIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconSize = 20,
    this.selected,
    this.danger = false,
  }) : round = false;

  const AppIconButton.navigation({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  }) : round = true,
       iconSize = 20,
       selected = null,
       danger = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final side = round ? 40.0 : 36.0;
    final on = selected == true;
    final button = Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      toggled: selected,
      excludeSemantics: true,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          fixedSize: WidgetStatePropertyAll(Size.square(side)),
          minimumSize: WidgetStatePropertyAll(Size.square(side)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? Colors.transparent
                : danger
                ? c.danger
                : on
                ? c.selection
                : s.contains(WidgetState.pressed)
                ? c.pressed
                : s.contains(WidgetState.hovered)
                ? c.subtle
                : Colors.transparent,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.iconSecondary : c.icon,
          ),
          shape: WidgetStatePropertyAll(
            round
                ? const CircleBorder()
                : RoundedRectangleBorder(
                    borderRadius: const BorderRadius.all(
                      Radius.circular(appRadius),
                    ),
                    side: on
                        ? BorderSide(color: c.selectionOutline)
                        : BorderSide.none,
                  ),
          ),
        ),
        child: Builder(
          builder: (context) => AppIcon(
            icon,
            size: iconSize,
            color: onPressed == null
                ? c.iconSecondary
                : danger
                ? c.onDanger
                : on
                ? c.onSelection
                : c.icon,
          ),
        ),
      ),
    );
    return _Focusable(
      radius: round ? side / 2 : appRadius,
      child: onPressed == null
          ? button
          : AppTooltip(message: label, child: button),
    );
  }
}

/// One row of a menu.
///
/// [swatch] shows a color square before the label (the text Color tool);
/// [checked] marks the current choice of the menu.
class AppMenuEntry {
  final String label;
  final VoidCallback onSelected;
  final AppIconData? icon;
  final Color? swatch;
  final bool checked;
  final Key? key;
  const AppMenuEntry({
    required this.label,
    required this.onSelected,
    this.icon,
    this.swatch,
    this.checked = false,
    this.key,
  });
}

Widget _menuRow(AppMenuEntry entry, {WidgetStatesController? states}) =>
    Builder(
      builder: (context) => MenuItemButton(
        key: entry.key,
        onPressed: entry.onSelected,
        statesController: states,
        // Hover does not take the focus, so an open text editor keeps its
        // selection while a tool menu is used (B7 rule 5).
        requestFocusOnHover: false,
        leadingIcon: entry.swatch != null
            ? Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: entry.swatch,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: context.colors.control),
                ),
              )
            : entry.icon == null
            ? null
            : AppIcon(entry.icon!, size: 18),
        trailingIcon: entry.checked
            ? AppIcon(AppIcons.checkmarkCircle, size: 18)
            : null,
        child: Semantics(selected: entry.checked, child: Text(entry.label)),
      ),
    );

/// An icon button that opens a menu: a solid panel with text rows.
class AppMenuButton extends StatelessWidget {
  final AppIconData icon;
  final String label;
  final List<AppMenuEntry> entries;
  final bool round;
  const AppMenuButton({
    super.key,
    required this.icon,
    required this.label,
    required this.entries,
    this.round = false,
  });

  @override
  Widget build(BuildContext context) => MenuAnchor(
    alignmentOffset: const Offset(0, 6),
    menuChildren: [for (final entry in entries) _menuRow(entry)],
    builder: (context, controller, _) {
      void toggle() =>
          controller.isOpen ? controller.close() : controller.open();
      return round
          ? AppIconButton.navigation(
              icon: icon,
              label: label,
              onPressed: toggle,
            )
          : AppIconButton(icon: icon, label: label, onPressed: toggle);
    },
  );
}

/// The menu panel drawn in place, for the component gallery. [highlighted]
/// shows the row under the pointer.
class AppMenuPanel extends StatefulWidget {
  final List<AppMenuEntry> entries;
  final int? highlighted;
  const AppMenuPanel({super.key, required this.entries, this.highlighted});
  @override
  State<AppMenuPanel> createState() => _AppMenuPanelState();
}

class _AppMenuPanelState extends State<AppMenuPanel> {
  late final states = [
    for (var i = 0; i < widget.entries.length; i++)
      WidgetStatesController({
        if (i == widget.highlighted) WidgetState.hovered,
      }),
  ];
  @override
  void dispose() {
    for (final s in states) {
      s.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(appPanelRadius),
        border: Border.all(color: c.border),
        boxShadow: appPanelShadow(c),
      ),
      child: IntrinsicWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.entries.length; i++)
              _menuRow(widget.entries[i], states: states[i]),
          ],
        ),
      ),
    );
  }
}

/// A dialog: a solid panel with a title, content and text buttons. The
/// confirming action comes last.
class AppDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 480),
      child: content,
    ),
    actionsAlignment: MainAxisAlignment.end,
    actions: actions,
  );
}

/// Opens a dialog with no see-through layer behind it.
Future<T?> showAppDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showDialog<T>(
      context: context,
      barrierColor: Colors.transparent,
      builder: builder,
    );

/// The meaning of a toast.
enum AppToastTone { neutral, warning, danger }

/// A short message on a solid inverted panel. Warning and danger toasts
/// carry an orange or red mark with a dark icon.
class AppToast extends StatelessWidget {
  final String message;
  final AppToastTone tone;
  const AppToast({
    super.key,
    required this.message,
    this.tone = AppToastTone.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (mark, icon) = switch (tone) {
      AppToastTone.neutral => (null, AppIcons.checkmarkCircle),
      AppToastTone.warning => (c.warning, AppIcons.alertTriangle),
      AppToastTone.danger => (c.danger, AppIcons.alertDiamond),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
      decoration: BoxDecoration(
        color: c.inverse,
        borderRadius: BorderRadius.circular(appPanelRadius),
        boxShadow: appPanelShadow(c),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: mark,
              borderRadius: BorderRadius.circular(appRadius),
            ),
            child: AppIcon(
              icon,
              size: 18,
              color: mark == null ? c.onInverse : c.onWarning,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium!.copyWith(color: c.onInverse),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows an [AppToast] at the bottom of the window.
void showAppToast(
  BuildContext context,
  String message, {
  AppToastTone tone = AppToastTone.neutral,
}) => ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    padding: EdgeInsets.zero,
    content: Center(
      child: AppToast(message: message, tone: tone),
    ),
  ),
);

/// The shared Asodya logo and the application title. A tap goes home.
class AppBrand extends StatelessWidget {
  final VoidCallback onHome;

  /// Hide the title on very narrow windows.
  final bool showTitle;
  final String homeLabel;
  const AppBrand({
    super.key,
    required this.onHome,
    required this.homeLabel,
    this.showTitle = true,
  });

  @override
  Widget build(BuildContext context) => _Focusable(
    child: Semantics(
      link: true,
      label: homeLabel,
      excludeSemantics: !showTitle,
      child: TextButton(
        key: const Key('brand-home'),
        onPressed: onHome,
        style:
            appButtonStyle(
              context.colors,
              Theme.of(context).textTheme,
              AppButtonKind.subtle,
            ).copyWith(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
              backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'lib/presentation/frontend/assets/images/asodya_logo.png',
              package: 'annotations_shared',
              height: 30,
              excludeFromSemantics: true,
            ),
            if (showTitle) ...[
              const SizedBox(width: 10),
              Text(
                'Annotations',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
