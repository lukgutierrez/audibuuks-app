import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color primaryAmber = Color(0xFFF5A623);
  static const Color secondaryAmber = Color(0xFFFFC107);
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color cardBackground = Color(0xFF1A1B1E);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      primaryColor: primaryAmber,
      colorScheme: const ColorScheme.dark(
        primary: primaryAmber,
        secondary: secondaryAmber,
        surface: darkSurface,
      ),
      fontFamily: GoogleFonts.inter().fontFamily,
      useMaterial3: true,
    );
  }
}
