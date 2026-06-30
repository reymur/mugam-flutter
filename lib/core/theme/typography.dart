import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'colors.dart';

TextTheme buildTextTheme() {
  return GoogleFonts.interTextTheme(
    const TextTheme(
      displayLarge: TextStyle(color: kText),
      displayMedium: TextStyle(color: kText),
      displaySmall: TextStyle(color: kText),
      headlineLarge: TextStyle(color: kText),
      headlineMedium: TextStyle(color: kText),
      headlineSmall: TextStyle(color: kText),
      titleLarge: TextStyle(color: kText),
      titleMedium: TextStyle(color: kText),
      titleSmall: TextStyle(color: kMuted),
      bodyLarge: TextStyle(color: kText),
      bodyMedium: TextStyle(color: kText),
      bodySmall: TextStyle(color: kMuted),
      labelLarge: TextStyle(color: kText),
      labelMedium: TextStyle(color: kMuted),
      labelSmall: TextStyle(color: kMuted),
    ),
  );
}
