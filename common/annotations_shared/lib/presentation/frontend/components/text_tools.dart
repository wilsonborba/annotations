import 'package:flutter/material.dart';

import '../../../core/paper_settings.dart';
import '../../../domain/services/ink_outline.dart' show colorArgb;
import 'controls.dart';
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

/// The text tools of Type mode (B7 rule 3): size, bold, italic,
/// strikethrough and color. They act on the selected text only; [format] is
/// the formatting of the selection in the stored span fields.
///
/// The panel sits in the same tap region as the text editor and its buttons
/// do not take the focus, so the selection stays while a tool is used (B7
/// rule 5).
class TextTools extends StatelessWidget {
  final Map<String, Object?> format;
  final num baseSize;
  final PaperSettings settings;
  final ValueChanged<String> onToggle;
  final ValueChanged<num> onSize;
  final ValueChanged<String?> onColor;
  const TextTools({
    super.key,
    required this.format,
    required this.baseSize,
    required this.onToggle,
    required this.onSize,
    required this.onColor,
    this.settings = const PaperSettings(),
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = format['size'] as num? ?? baseSize;
    final color = format['color'] as String?;
    Widget toggle(String field, AppIconData icon) => AppIconButton(
      key: Key('text-tool-$field'),
      icon: icon,
      label: context.tr(field),
      selected: format[field] == true,
      onPressed: () => onToggle(field),
    );
    return TextFieldTapRegion(
      child: FocusScope(
        canRequestFocus: false,
        child: Semantics(
          container: true,
          label: context.tr('textTools'),
          child: Container(
            key: const Key('text-tools'),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(appPanelRadius),
              border: Border.all(color: c.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppMenuButton(
                  key: const Key('text-tool-size'),
                  icon: AppIcons.textSize,
                  label: context.tr('textSize'),
                  entries: [
                    for (final s in settings.textSizes)
                      AppMenuEntry(
                        key: Key('text-size-$s'),
                        label: '$s',
                        checked: s == size,
                        onSelected: () => onSize(s),
                      ),
                  ],
                ),
                toggle('bold', AppIcons.bold),
                toggle('italic', AppIcons.italic),
                toggle('strikethrough', AppIcons.strikethrough),
                AppMenuButton(
                  key: const Key('text-tool-color'),
                  icon: AppIcons.color,
                  label: context.tr('textColor'),
                  entries: [
                    AppMenuEntry(
                      key: const Key('text-color-automatic'),
                      label: context.tr('colorAutomatic'),
                      swatch: c.text,
                      checked: color == null,
                      onSelected: () => onColor(null),
                    ),
                    for (final (name, value) in settings.textColors)
                      AppMenuEntry(
                        key: Key('text-color-$name'),
                        label: context.tr(name),
                        swatch: Color(colorArgb(value, 1)),
                        checked: color?.toUpperCase() == value.toUpperCase(),
                        onSelected: () => onColor(value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
