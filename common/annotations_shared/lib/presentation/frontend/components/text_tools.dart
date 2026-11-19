import 'package:flutter/material.dart';

import '../../../core/paper_settings.dart';
import '../../../domain/services/ink_outline.dart' show colorArgb;
import 'controls.dart';
import 'draw_controls.dart' show CustomColorPicker;
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

/// The text tools of Type mode (B7 rule 3): size, bold, italic,
/// strikethrough and color. They act on the selected text only; [format] is
/// the formatting of the selection in the stored span fields.
///
/// The Color tool offers Automatic, the pen palette (B6.2) and the custom
/// picker, which opens under the tools and applies the color when the user
/// lets go of a control.
///
/// The panel sits in the same tap region as the text editor and its buttons
/// do not take the focus, so the selection stays while a tool is used (B7
/// rule 5).
class TextTools extends StatefulWidget {
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
    this.axis = Axis.horizontal,
    this.bare = false,
  });

  /// The direction of the tools, and whether they sit inside the editor
  /// toolbar without their own panel (annotations#31).
  final Axis axis;
  final bool bare;

  @override
  State<TextTools> createState() => _TextToolsState();
}

class _TextToolsState extends State<TextTools> {
  bool _custom = false;

  @override
  Widget build(BuildContext context) {
    final TextTools(
      :format,
      :baseSize,
      :settings,
      :onToggle,
      :onSize,
      :onColor,
    ) = widget;
    final c = context.colors;
    final size = format['size'] as num? ?? baseSize;
    final color = format['color'] as String?;
    final fixed =
        color == null ||
        settings.textColors.any(
          (e) => e.$2.toUpperCase() == color.toUpperCase(),
        );
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
            padding: widget.bare ? EdgeInsets.zero : const EdgeInsets.all(2),
            decoration: widget.bare
                ? null
                : BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(appPanelRadius),
                    border: Border.all(color: c.border),
                  ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flex(
                  direction: widget.axis,
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
                          onSelected: () {
                            setState(() => _custom = false);
                            onColor(null);
                          },
                        ),
                        for (final (name, value) in settings.textColors)
                          AppMenuEntry(
                            key: Key('text-color-$name'),
                            label: context.tr(name),
                            swatch: Color(colorArgb(value, 1)),
                            checked:
                                color?.toUpperCase() == value.toUpperCase(),
                            onSelected: () {
                              setState(() => _custom = false);
                              onColor(value);
                            },
                          ),
                        AppMenuEntry(
                          key: const Key('text-color-custom'),
                          label: context.tr('customColor'),
                          icon: fixed ? AppIcons.add : null,
                          swatch: fixed ? null : Color(colorArgb(color, 1)),
                          checked: !fixed,
                          onSelected: () => setState(() => _custom = true),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_custom)
                  Container(
                    width: settings.colorPickerWidth,
                    padding: const EdgeInsets.all(8),
                    child: CustomColorPicker(
                      key: const Key('text-color-picker'),
                      color: color ?? settings.textColors.first.$2,
                      // One formatting step when the user lets go of a control.
                      onChanged: (value, done) {
                        if (done) onColor(value);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
