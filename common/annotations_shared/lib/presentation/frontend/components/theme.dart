import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tokens.dart';

/// Ubuntu Sans for every label. IBM Plex Sans Thai only draws the Thai
/// glyphs that Ubuntu Sans does not have.
const appFontFamily = 'packages/annotations_shared/Ubuntu Sans';
const appFontFallback = ['packages/annotations_shared/IBM Plex Sans Thai'];

/// Corner radius of buttons, fields and menu rows. Small and square: no
/// bubbly shapes.
const appRadius = 6.0;

/// Corner radius of cards, menus, dialogs and toasts.
const appPanelRadius = 10.0;

/// One solid shadow for raised surfaces (menus, dialogs, toasts). No blur
/// on the surface itself, which stays opaque.
List<BoxShadow> appPanelShadow(AppColors c) => [
  BoxShadow(
    color: c.isDark ? const Color(0x66000000) : const Color(0x24000000),
    blurRadius: 16,
    offset: const Offset(0, 6),
  ),
];

/// The type scale. Large text (24 regular, 19 bold and up) may use 3:1.
TextTheme appTextTheme(AppColors c) {
  TextStyle style(double size, FontWeight weight, double height, Color color) =>
      TextStyle(
        fontFamily: appFontFamily,
        fontFamilyFallback: appFontFallback,
        fontSize: size,
        fontWeight: weight,
        height: height,
        color: color,
        letterSpacing: 0,
      );
  return TextTheme(
    displayLarge: style(48, FontWeight.w700, 1.1, c.text),
    displayMedium: style(40, FontWeight.w700, 1.12, c.text),
    displaySmall: style(34, FontWeight.w700, 1.15, c.text),
    headlineLarge: style(40, FontWeight.w700, 1.12, c.text),
    headlineMedium: style(28, FontWeight.w700, 1.2, c.text),
    headlineSmall: style(22, FontWeight.w700, 1.25, c.text),
    titleLarge: style(20, FontWeight.w700, 1.3, c.text),
    titleMedium: style(17, FontWeight.w600, 1.35, c.text),
    titleSmall: style(15, FontWeight.w600, 1.4, c.text),
    bodyLarge: style(17, FontWeight.w400, 1.6, c.text),
    bodyMedium: style(15, FontWeight.w400, 1.5, c.text),
    bodySmall: style(13, FontWeight.w400, 1.45, c.textSecondary),
    labelLarge: style(15, FontWeight.w600, 1.2, c.text),
    labelMedium: style(13, FontWeight.w600, 1.2, c.text),
    labelSmall: style(12, FontWeight.w600, 1.2, c.textSecondary),
  );
}

/// The Annotations theme. Material widgets that remain take the design
/// system colors, type, corners and solid surfaces; no ripple, no tint, no
/// see-through layer.
ThemeData appTheme(Brightness brightness) {
  final c = AppColors.of(brightness);
  final text = appTextTheme(c);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accent,
    onPrimaryContainer: c.onAccent,
    secondary: c.selection,
    onSecondary: c.onSelection,
    secondaryContainer: c.selection,
    onSecondaryContainer: c.onSelection,
    tertiary: c.link,
    onTertiary: c.page,
    error: c.danger,
    onError: c.onDanger,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.subtle,
    surfaceContainerHigh: c.subtle,
    surfaceContainerHighest: c.pressed,
    outline: c.control,
    outlineVariant: c.border,
    inverseSurface: c.inverse,
    onInverseSurface: c.onInverse,
    inversePrimary: c.selection,
    shadow: const Color(0xFF000000),
    scrim: Colors.transparent,
    surfaceTint: Colors.transparent,
  );
  final fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(appRadius),
    borderSide: BorderSide(color: c.control),
  );
  final panelShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(appPanelRadius),
    side: BorderSide(color: c.border),
  );
  final noOverlay = WidgetStateProperty.resolveWith<Color?>(
    (states) => states.contains(WidgetState.pressed)
        ? c.pressed
        : states.contains(WidgetState.hovered)
        ? c.subtle
        : null,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [c],
    fontFamily: appFontFamily,
    fontFamilyFallback: appFontFallback,
    textTheme: text,
    primaryTextTheme: text,
    scaffoldBackgroundColor: c.page,
    canvasColor: c.surface,
    cardColor: c.surface,
    dividerColor: c.border,
    disabledColor: c.textSecondary,
    hoverColor: c.subtle,
    focusColor: Colors.transparent,
    highlightColor: c.pressed,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    iconTheme: IconThemeData(color: c.icon, size: 20),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.page,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: c.border)),
      titleTextStyle: text.titleLarge,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.text,
      selectionColor: c.selection,
      selectionHandleColor: c.selectionOutline,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      hoverColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: text.bodyMedium!.copyWith(color: c.textSecondary),
      floatingLabelStyle: text.bodyMedium!.copyWith(color: c.text),
      hintStyle: text.bodyMedium!.copyWith(color: c.textSecondary),
      prefixIconColor: c.iconSecondary,
      suffixIconColor: c.iconSecondary,
      border: fieldBorder,
      enabledBorder: fieldBorder,
      // Focus: the selection mark, darker on light surfaces.
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: c.selectionOutline, width: 2),
      ),
      errorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: c.danger, width: 2),
      ),
      focusedErrorBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: c.danger, width: 2),
      ),
      disabledBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: c.border),
      ),
      errorStyle: text.bodySmall!.copyWith(color: c.text),
    ),
    // Material buttons that remain look like the Annotations buttons.
    filledButtonTheme: FilledButtonThemeData(
      style: appButtonStyle(c, text, AppButtonKind.primary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: appButtonStyle(c, text, AppButtonKind.primary),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: appButtonStyle(c, text, AppButtonKind.secondary),
    ),
    textButtonTheme: TextButtonThemeData(
      style: appButtonStyle(c, text, AppButtonKind.subtle),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.icon),
        overlayColor: noOverlay,
        splashFactory: NoSplash.splashFactory,
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(appRadius)),
          ),
        ),
      ),
    ),
    menuTheme: MenuThemeData(style: _menuStyle(c)),
    menuButtonTheme: MenuButtonThemeData(style: appMenuItemStyle(c, text)),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: _menuStyle(c),
      textStyle: text.bodyMedium,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x55000000),
      shape: panelShape,
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: const Color(0x66000000),
      // No see-through scrim behind a dialog: the page stays as it is.
      barrierColor: Colors.transparent,
      shape: panelShape,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      textStyle: text.labelMedium!.copyWith(color: c.onInverse),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: c.inverse,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      width: 420,
      insetPadding: const EdgeInsets.all(16),
      contentTextStyle: text.bodyMedium!.copyWith(color: c.onInverse),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.subtle,
      side: BorderSide(color: c.border),
      labelStyle: text.labelMedium,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(appRadius)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.iconSecondary,
      linearTrackColor: c.subtle,
      circularTrackColor: Colors.transparent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(c.control),
      radius: const Radius.circular(appRadius),
    ),
  );
}

/// The attention level of a button. A page has one [primary] button at most
/// (one high-attention element per page).
enum AppButtonKind {
  /// The main action: purple fill, white text.
  primary,

  /// Other actions: solid surface with a visible border.
  secondary,

  /// Low-emphasis actions: no fill until hover.
  subtle,

  /// A critical action (delete, the dangerous eraser): red fill, dark text,
  /// always with a text label.
  danger,
}

ButtonStyle appButtonStyle(AppColors c, TextTheme text, AppButtonKind kind) {
  final (background, foreground, border) = switch (kind) {
    AppButtonKind.primary => (c.accent, c.onAccent, null),
    AppButtonKind.secondary => (c.surface, c.text, c.control),
    AppButtonKind.subtle => (Colors.transparent, c.text, null),
    AppButtonKind.danger => (c.danger, c.onDanger, null),
  };
  final neutral = background == c.surface || background == Colors.transparent;
  return ButtonStyle(
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return kind == AppButtonKind.subtle ? background : c.subtle;
      }
      if (neutral) {
        if (states.contains(WidgetState.pressed)) return c.pressed;
        if (states.contains(WidgetState.hovered)) return c.subtle;
        return background;
      }
      if (states.contains(WidgetState.pressed)) {
        return Color.alphaBlend(const Color(0x33000000), background);
      }
      if (states.contains(WidgetState.hovered)) {
        return Color.alphaBlend(const Color(0x1A000000), background);
      }
      return background;
    }),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? c.textSecondary : foreground,
    ),
    iconColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? c.textSecondary : foreground,
    ),
    side: WidgetStateProperty.resolveWith(
      (s) => border == null
          ? BorderSide.none
          : BorderSide(
              color: s.contains(WidgetState.disabled) ? c.border : border,
            ),
    ),
    shape: const WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(appRadius)),
      ),
    ),
  );
}

MenuStyle _menuStyle(AppColors c) => MenuStyle(
  backgroundColor: WidgetStatePropertyAll(c.surface),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  elevation: const WidgetStatePropertyAll(6),
  shadowColor: const WidgetStatePropertyAll(Color(0x55000000)),
  padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
  side: WidgetStatePropertyAll(BorderSide(color: c.border)),
  shape: const WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(appPanelRadius)),
    ),
  ),
);

/// A menu row: neutral text, the selection fill while focused or hovered.
ButtonStyle appMenuItemStyle(AppColors c, TextTheme text) => ButtonStyle(
  textStyle: WidgetStatePropertyAll(text.bodyMedium),
  minimumSize: const WidgetStatePropertyAll(Size(180, 36)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
  splashFactory: NoSplash.splashFactory,
  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.focused) ||
            states.contains(WidgetState.hovered)
        ? c.selection
        : Colors.transparent,
  ),
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled)
        ? c.textSecondary
        : states.contains(WidgetState.focused) ||
              states.contains(WidgetState.hovered)
        ? c.onSelection
        : c.text,
  ),
  iconColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.focused) ||
            states.contains(WidgetState.hovered)
        ? c.onSelection
        : c.icon,
  ),
  shape: const WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(appRadius)),
    ),
  ),
);

bool _licensesAdded = false;

/// Adds the font and icon licenses to the license page of the application.
void registerDesignLicenses() {
  if (_licensesAdded) return;
  _licensesAdded = true;
  const base = 'packages/annotations_shared/lib/presentation/frontend/assets';
  LicenseRegistry.addLicense(() async* {
    for (final (package, file) in const [
      ('Ubuntu Sans', '$base/fonts/UbuntuSans-LICENCE.txt'),
      ('IBM Plex Sans Thai', '$base/fonts/IBMPlexSansThai-LICENSE.txt'),
      ('Spectrum 2 workflow icons', '$base/icons/NOTICE'),
      ('Spectrum 2 workflow icons', '$base/icons/LICENSE'),
    ]) {
      yield LicenseEntryWithLineBreaks([
        package,
      ], await rootBundle.loadString(file));
    }
  });
}
