import 'package:flutter/material.dart';

/// The Asodya colors (H7 section 2, from the asodya.com code).
///
/// Ink colors of a note are not here: they never change with the mode, so
/// the theme never touches them.
abstract final class AppPalette {
  static const green = Color(0xFF6EFF00);
  static const purple = Color(0xFFA201FF);
  static const cyan = Color(0xFF00E5FF);
  static const blue = Color(0xFF3D5AFE);
  static const orange = Color(0xFFFF9100);
  static const red = Color(0xFFFF1744);
  static const mint = Color(0xFF00E676);
  static const teal = Color(0xFF1DE9B6);

  /// The dark page of asodya.com.
  static const night = Color(0xFF0B0C10);
  static const white = Color(0xFFFFFFFF);

  /// The color pairs. They appear in small amounts, one pair per Features
  /// group, for its icon tile and its marks.
  static const pairs = <(Color, Color)>[
    (green, purple),
    (cyan, blue),
    (orange, red),
    (mint, teal),
  ];
}

/// Colors with fixed jobs, the same jobs in light and dark mode.
///
/// - [accent] is the main action: a purple fill with [onAccent] white text.
/// - [selection] is selection, the current tab, the active tool and focus:
///   always a green fill with dark text, never green text on light paper.
///   [selectionOutline] is the darker mark that keeps it visible on light
///   surfaces, including the keyboard focus ring.
/// - [link] is purple text in light mode and green text in dark mode.
/// - [danger] is red (delete, the dangerous eraser, the space limit) and
///   [warning] is orange. Both are fills or marks, never light-mode text.
/// - The page and the surfaces stay neutral and solid.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  final Brightness brightness;

  /// The page behind everything.
  final Color page;

  /// Cards, menus, dialogs and fields.
  final Color surface;

  /// Hover and grouped areas.
  final Color subtle;

  /// Pressed controls.
  final Color pressed;

  /// Separators that only decorate.
  final Color border;

  /// Borders that show where a control is (3:1 against the page).
  final Color control;

  final Color text;
  final Color textSecondary;
  final Color link;
  final Color icon;
  final Color iconSecondary;
  final Color accent;
  final Color onAccent;
  final Color selection;
  final Color onSelection;
  final Color selectionOutline;
  final Color danger;
  final Color onDanger;
  final Color warning;
  final Color onWarning;

  /// Tooltips and toasts: a solid, inverted surface.
  final Color inverse;
  final Color onInverse;

  const AppColors({
    required this.brightness,
    required this.page,
    required this.surface,
    required this.subtle,
    required this.pressed,
    required this.border,
    required this.control,
    required this.text,
    required this.textSecondary,
    required this.link,
    required this.icon,
    required this.iconSecondary,
    required this.accent,
    required this.onAccent,
    required this.selection,
    required this.onSelection,
    required this.selectionOutline,
    required this.danger,
    required this.onDanger,
    required this.warning,
    required this.onWarning,
    required this.inverse,
    required this.onInverse,
  });

  static const light = AppColors(
    brightness: Brightness.light,
    page: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    subtle: Color(0xFFF5F5F7),
    pressed: Color(0xFFECECEF),
    border: Color(0xFFDDDDE2),
    control: Color(0xFF8A8B93),
    text: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF5F6068),
    link: AppPalette.purple,
    icon: Color(0xFF1D1D1F),
    iconSecondary: Color(0xFF5F6068),
    accent: AppPalette.purple,
    onAccent: AppPalette.white,
    selection: AppPalette.green,
    onSelection: AppPalette.night,
    selectionOutline: Color(0xFF2B6B00),
    danger: AppPalette.red,
    onDanger: AppPalette.night,
    warning: AppPalette.orange,
    onWarning: AppPalette.night,
    inverse: Color(0xFF1D1D1F),
    onInverse: AppPalette.white,
  );

  static const dark = AppColors(
    brightness: Brightness.dark,
    page: AppPalette.night,
    surface: Color(0xFF15171D),
    subtle: Color(0xFF1E2028),
    pressed: Color(0xFF262833),
    border: Color(0xFF2E3039),
    control: Color(0xFF6A6C76),
    text: Color(0xFFF2F2F5),
    textSecondary: Color(0xFFA1A3AD),
    link: AppPalette.green,
    icon: Color(0xFFF2F2F5),
    iconSecondary: Color(0xFFA1A3AD),
    accent: AppPalette.purple,
    onAccent: AppPalette.white,
    selection: AppPalette.green,
    onSelection: AppPalette.night,
    selectionOutline: AppPalette.green,
    danger: AppPalette.red,
    onDanger: AppPalette.night,
    warning: AppPalette.orange,
    onWarning: AppPalette.night,
    inverse: Color(0xFFF2F2F5),
    onInverse: AppPalette.night,
  );

  static AppColors of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  bool get isDark => brightness == Brightness.dark;

  /// The text tokens with the backgrounds they appear on. Normal text needs
  /// 4.5:1 on each of them.
  Map<String, (Color, List<Color>)> get textPairs => {
    'text': (text, [page, surface, subtle, pressed]),
    'textSecondary': (textSecondary, [page, surface, subtle, pressed]),
    'link': (link, [page, surface, subtle]),
    'onAccent': (onAccent, [accent]),
    'onSelection': (onSelection, [selection]),
    'onDanger': (onDanger, [danger]),
    'onWarning': (onWarning, [warning]),
    'onInverse': (onInverse, [inverse]),
  };

  /// Icons, control borders and focus marks with their backgrounds. They
  /// need 3:1.
  Map<String, (Color, List<Color>)> get iconPairs => {
    'icon': (icon, [page, surface, subtle, pressed]),
    'iconSecondary': (iconSecondary, [page, surface, subtle, pressed]),
    'danger': (danger, [page, surface, subtle]),
    'control': (control, [page, surface]),
    'selectionOutline': (selectionOutline, [page, surface, subtle]),
    'accentFill': (accent, [page, surface]),
    'onAccentIcon': (onAccent, [accent]),
    'onSelectionIcon': (onSelection, [selection]),
    'onDangerIcon': (onDanger, [danger]),
    'onWarningIcon': (onWarning, [warning]),
    'onInverseIcon': (onInverse, [inverse]),
  };

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// WCAG contrast ratio of two opaque colors.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

extension AppColorsContext on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ??
      AppColors.of(Theme.of(this).brightness);
}
