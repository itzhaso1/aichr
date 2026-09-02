import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'hasim_colors.dart';

abstract final class HasimTypography {
  static TextTheme textTheme() {
    final base = GoogleFonts.cairoTextTheme();
    return base.copyWith(
      displayLarge: GoogleFonts.cairo(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: HasimColors.ink,
      ),
      headlineMedium: GoogleFonts.cairo(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: HasimColors.ink,
      ),
      titleLarge: GoogleFonts.cairo(
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: HasimColors.ink,
      ),
      titleMedium: GoogleFonts.cairo(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: HasimColors.ink,
      ),
      titleSmall: GoogleFonts.cairo(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: HasimColors.ink,
      ),
      bodyLarge: GoogleFonts.cairo(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: HasimColors.ink,
      ),
      bodyMedium: GoogleFonts.cairo(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: HasimColors.ink,
      ),
      bodySmall: GoogleFonts.cairo(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: HasimColors.muted,
      ),
      labelLarge: GoogleFonts.cairo(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: HasimColors.ink,
      ),
      labelSmall: GoogleFonts.cairo(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: HasimColors.muted,
      ),
    );
  }

  static TextStyle get price => GoogleFonts.cairo(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: HasimColors.ink,
      );

  static TextStyle get caption => GoogleFonts.cairo(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: HasimColors.muted,
      );
}
