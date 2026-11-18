import 'package:annotations_shared/presentation/frontend/components/icons.dart';
import 'package:annotations_shared/presentation/frontend/components/theme.dart';
import 'package:annotations_shared/presentation/frontend/components/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final colors in [AppColors.light, AppColors.dark]) {
    final mode = colors.isDark ? 'dark' : 'light';
    test('every text token reaches 4.5:1 in $mode mode', () {
      for (final MapEntry(key: name, value: (fore, backs))
          in colors.textPairs.entries) {
        for (final back in backs) {
          final ratio = contrastRatio(fore, back);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason:
                '$mode $name on ${back.toARGB32().toRadixString(16)}: '
                '${ratio.toStringAsFixed(2)}',
          );
        }
      }
    });

    test('every icon and mark token reaches 3:1 in $mode mode', () {
      for (final MapEntry(key: name, value: (fore, backs))
          in colors.iconPairs.entries) {
        for (final back in backs) {
          final ratio = contrastRatio(fore, back);
          expect(
            ratio,
            greaterThanOrEqualTo(3),
            reason:
                '$mode $name on ${back.toARGB32().toRadixString(16)}: '
                '${ratio.toStringAsFixed(2)}',
          );
        }
      }
    });

    test('text tokens avoid the forbidden colors in $mode mode', () {
      final forbidden = colors.isDark
          ? [AppPalette.purple, AppPalette.blue]
          : [AppPalette.green, AppPalette.cyan, AppPalette.orange];
      for (final MapEntry(key: name, value: (fore, _))
          in colors.textPairs.entries) {
        expect(forbidden, isNot(contains(fore)), reason: '$mode $name');
      }
    });

    test('colors keep their fixed jobs in $mode mode', () {
      expect(colors.accent, AppPalette.purple);
      expect(colors.onAccent, AppPalette.white);
      expect(colors.selection, AppPalette.green);
      expect(colors.onSelection, AppPalette.night);
      expect(colors.link, colors.isDark ? AppPalette.green : AppPalette.purple);
      expect(colors.danger, AppPalette.red);
      expect(colors.warning, AppPalette.orange);
    });

    test('the $mode theme uses solid surfaces and the app fonts', () {
      final theme = appTheme(colors.brightness);
      for (final color in [
        colors.page,
        colors.surface,
        colors.subtle,
        colors.pressed,
        colors.inverse,
        theme.scaffoldBackgroundColor,
        theme.canvasColor,
        theme.dialogTheme.backgroundColor!,
        theme.popupMenuTheme.color!,
      ]) {
        expect(color.a, 1.0);
      }
      expect(theme.dialogTheme.barrierColor, Colors.transparent);
      expect(theme.splashFactory, NoSplash.splashFactory);
      expect(theme.textTheme.bodyMedium!.fontFamily, appFontFamily);
      expect(theme.textTheme.bodyMedium!.fontFamilyFallback, appFontFallback);
      expect(theme.extension<AppColors>(), colors);
    });
  }

  test('the color pairs are the asodya.com pairs', () {
    expect(AppPalette.pairs, [
      (const Color(0xFF6EFF00), const Color(0xFFA201FF)),
      (const Color(0xFF00E5FF), const Color(0xFF3D5AFE)),
      (const Color(0xFFFF9100), const Color(0xFFFF1744)),
      (const Color(0xFF00E676), const Color(0xFF1DE9B6)),
    ]);
  });

  test('every Spectrum icon parses inside the 20 x 20 grid', () {
    for (final icon in AppIcons.all) {
      expect(icon.parsed, isNotEmpty, reason: icon.name);
      for (final path in icon.parsed) {
        final bounds = path.getBounds();
        expect(bounds.isEmpty, isFalse, reason: icon.name);
        expect(bounds.left, greaterThanOrEqualTo(-0.01), reason: icon.name);
        expect(bounds.top, greaterThanOrEqualTo(-0.01), reason: icon.name);
        expect(bounds.right, lessThanOrEqualTo(20.01), reason: icon.name);
        expect(bounds.bottom, lessThanOrEqualTo(20.01), reason: icon.name);
      }
    }
  });

  test('the path parser reads compact SVG numbers', () {
    final path = parseSvgPath('M1,1h2v2H1Zm.5.5l.25.25');
    expect(path.getBounds(), const Rect.fromLTRB(1, 1, 3, 3));
    expect(() => parseSvgPath('1,1'), throwsFormatException);
    expect(() => parseSvgPath('M0,0A1,1,0,0,1,2,2'), throwsFormatException);
  });
}
