/// Hasim brand colors — mirrored from `resources/css/app.css` `:root`.
library;

import 'package:flutter/material.dart';

abstract final class HasimColors {
  static const Color brand = Color(0xFF06C2A4);
  static const Color brandDark = Color(0xFF049E86);
  static const Color brandSoft = Color(0xFFE8FAF6);

  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color border = Color(0xFFE2E8F0);
  static const Color page = Color(0xFFF1F5F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceSoft = Color(0xFFF8FAFC);

  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSoft = Color(0xFFFFF1F2);
  static const Color warning = Color(0xFFD97706);
  static const Color warningSoft = Color(0xFFFFFBEB);

  /// Cart primary CTA on web uses emerald-600.
  static const Color cta = Color(0xFF059669);
  static const Color ctaDark = Color(0xFF047857);
  static const Color ctaSoft = Color(0xFFECFDF5);

  static const Color occupied = Color(0xFFE11D48);
  static const Color occupiedSoft = Color(0xFFFFF1F2);
  static const Color available = Color(0xFF059669);
  static const Color availableSoft = Color(0xFFECFDF5);

  static const Color navActiveBg = Color(0xFF0F172A);
  static const Color navIdleBg = Color(0xFFF1F5F9);
}
