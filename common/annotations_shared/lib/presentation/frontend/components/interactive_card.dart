import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// The visible state of an interactive surface, for tests and styling.
enum CardState { rest, hover, focus, pressed }

/// True when focus marks show: keyboard use, not touch (focus-visible).
bool get _focusVisible =>
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

/// Keyboard and pointer handling shared by the card and the link: focus
/// with Enter and Space to activate, hover through a mouse region with the
/// hand pointer, press through the gesture.
class _Control extends StatelessWidget {
  const _Control({
    required this.onTap,
    required this.onHover,
    required this.onFocus,
    required this.onPress,
    required this.child,
  });

  final VoidCallback onTap;
  final ValueChanged<bool> onHover, onFocus, onPress;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: onFocus,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space)) {
        onTap();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onPress(true),
        onTapCancel: () => onPress(false),
        onTapUp: (_) => onPress(false),
        onTap: onTap,
        child: child,
      ),
    ),
  );
}

/// A card that is one control (owner design review 2026-11-20): hover
/// lifts the border and the surface, keyboard focus shows the green focus
/// ring, press darkens the surface, the pointer is a hand. Motion is short
/// and stops under reduced motion.
class InteractiveCard extends StatefulWidget {
  const InteractiveCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(24),
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final String? semanticLabel;

  @override
  State<InteractiveCard> createState() => InteractiveCardState();
}

class InteractiveCardState extends State<InteractiveCard> {
  bool _hover = false, _focus = false, _pressed = false;

  CardState get state => _pressed
      ? CardState.pressed
      : _focus && _focusVisible
      ? CardState.focus
      : _hover
      ? CardState.hover
      : CardState.rest;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final still = MediaQuery.of(context).disableAnimations;
    final enabled = widget.onTap != null;
    final ring = enabled && _focus && _focusVisible;
    final lifted = enabled && (_hover || ring) && !_pressed;
    final card = AnimatedContainer(
      key: const Key('card-surface'),
      duration: still ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      transform: Matrix4.translationValues(0, lifted && !still ? -2 : 0, 0),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: _pressed
            ? c.pressed
            : lifted
            ? c.subtle
            : c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ring
              ? c.selectionOutline
              : lifted
              ? c.control
              : c.border,
          width: ring ? 2 : 1,
        ),
      ),
      child: widget.child,
    );
    if (!enabled) return card;
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: _Control(
        onTap: widget.onTap!,
        onHover: (v) => setState(() => _hover = v),
        onFocus: (v) => setState(() => _focus = v),
        onPress: (v) => setState(() => _pressed = v),
        child: card,
      ),
    );
  }
}

/// A text link with hover, focus and pressed states: purple in light mode,
/// green in dark mode (H7 rule 4).
class AppLink extends StatefulWidget {
  const AppLink({
    super.key,
    required this.label,
    required this.onTap,
    this.style,
    this.trailing = false,
  });

  final String label;
  final VoidCallback onTap;
  final TextStyle? style;

  /// Shows a forward chevron after the label.
  final bool trailing;

  @override
  State<AppLink> createState() => AppLinkState();
}

class AppLinkState extends State<AppLink> {
  bool _hover = false, _focus = false, _pressed = false;

  CardState get state => _pressed
      ? CardState.pressed
      : _focus && _focusVisible
      ? CardState.focus
      : _hover
      ? CardState.hover
      : CardState.rest;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = widget.style ?? Theme.of(context).textTheme.bodyMedium!;
    final ring = _focus && _focusVisible;
    return Semantics(
      link: true,
      child: _Control(
        onTap: widget.onTap,
        onHover: (v) => setState(() => _hover = v),
        onFocus: (v) => setState(() => _focus = v),
        onPress: (v) => setState(() => _pressed = v),
        child: Container(
          key: const Key('link-surface'),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: _pressed ? c.pressed : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: ring ? c.selectionOutline : Colors.transparent,
              width: 2,
            ),
          ),
          child: Text.rich(
            TextSpan(
              text: widget.label,
              children: [if (widget.trailing) const TextSpan(text: '  ›')],
            ),
            style: base.copyWith(
              color: c.link,
              fontWeight: FontWeight.w600,
              decoration: _hover || ring
                  ? TextDecoration.underline
                  : TextDecoration.none,
              decorationColor: c.link,
              decorationThickness: 2,
            ),
          ),
        ),
      ),
    );
  }
}
