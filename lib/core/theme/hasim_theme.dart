import 'package:flutter/material.dart';

import 'hasim_colors.dart';
import 'hasim_radius.dart';
import 'hasim_typography.dart';

abstract final class HasimTheme {
  static ThemeData light() {
    final text = HasimTypography.textTheme();
    final scheme = ColorScheme.fromSeed(
      seedColor: HasimColors.brand,
      primary: HasimColors.brand,
      secondary: HasimColors.cta,
      surface: HasimColors.surface,
      error: HasimColors.danger,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: HasimColors.page,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: HasimColors.surface.withValues(alpha: 0.95),
        foregroundColor: HasimColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: HasimColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HasimRadius.lg),
          side: const BorderSide(color: HasimColors.border),
        ),
      ),
      dividerColor: HasimColors.border,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: HasimColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HasimRadius.md),
          borderSide: const BorderSide(color: HasimColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HasimRadius.md),
          borderSide: const BorderSide(color: HasimColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HasimRadius.md),
          borderSide: const BorderSide(color: HasimColors.brand, width: 1.4),
        ),
        labelStyle: text.bodySmall,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: HasimColors.cta,
          foregroundColor: Colors.white,
          disabledBackgroundColor: HasimColors.cta.withValues(alpha: 0.45),
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HasimRadius.sm),
          ),
          textStyle: text.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: HasimColors.ctaDark,
          side: const BorderSide(color: HasimColors.cta),
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HasimRadius.sm),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: HasimColors.surface,
        contentTextStyle: text.bodyMedium?.copyWith(color: HasimColors.ctaDark),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HasimRadius.md),
          side: const BorderSide(color: Color(0xFFA7F3D0)),
        ),
      ),
    );
  }
}
