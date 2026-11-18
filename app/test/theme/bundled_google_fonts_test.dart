import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:totals/theme/app_font_option.dart';

/// google_fonts names a loaded font `<Family>_<variant>`, e.g.
/// `SpaceGrotesk_regular` or `Inter_500`, and looks for the bundled file
/// `<Family>-<Weight>.ttf`.
String _assetNameFor(String fontFamily) {
  const weights = {
    'regular': 'Regular',
    '100': 'Thin',
    '200': 'ExtraLight',
    '300': 'Light',
    '500': 'Medium',
    '600': 'SemiBold',
    '700': 'Bold',
    '800': 'ExtraBold',
    '900': 'Black',
  };
  final separator = fontFamily.lastIndexOf('_');
  final family = fontFamily.substring(0, separator);
  final variant = fontFamily.substring(separator + 1);
  return '$family-${weights[variant] ?? variant}.ttf';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  test('every font variant the themes request is bundled', () {
    final requested = <String>{};
    for (final brightness in Brightness.values) {
      final base = ThemeData(useMaterial3: true, brightness: brightness);
      for (final option in AppFontOption.values) {
        for (final theme in [
          AppFontTheme.applyRedesign(base, option),
          AppFontTheme.applyLegacy(base, option),
        ]) {
          for (final textTheme in [theme.textTheme, theme.primaryTextTheme]) {
            for (final style in [
              textTheme.displayLarge,
              textTheme.displayMedium,
              textTheme.displaySmall,
              textTheme.headlineLarge,
              textTheme.headlineMedium,
              textTheme.headlineSmall,
              textTheme.titleLarge,
              textTheme.titleMedium,
              textTheme.titleSmall,
              textTheme.bodyLarge,
              textTheme.bodyMedium,
              textTheme.bodySmall,
              textTheme.labelLarge,
              textTheme.labelMedium,
              textTheme.labelSmall,
            ]) {
              final family = style?.fontFamily;
              if (family != null && family.contains('_')) {
                requested.add(family);
              }
            }
          }
        }
      }
    }

    expect(requested, isNotEmpty);
    for (final family in requested) {
      final asset = File('assets/google_fonts/${_assetNameFor(family)}');
      expect(asset.existsSync(), isTrue, reason: '${asset.path} is missing');
    }
  });
}
