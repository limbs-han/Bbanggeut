import 'package:flutter/material.dart';

abstract final class AppColors {
  static const ink = Color(0xFF1D2926);
  static const muted = Color(0xFF6B7773);
  static const primary = Color(0xFF287D72);
  static const primaryDark = Color(0xFF18594F);
  static const mint = Color(0xFFDDF1EC);
  static const peach = Color(0xFFF6B39E);
  static const cream = Color(0xFFFFFBF4);
  static const surface = Color(0xFFFFFFFF);
  static const line = Color(0xFFE9E2D8);
  static const danger = Color(0xFFC75B50);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.light,
    primary: AppColors.primary,
    surface: AppColors.surface,
    error: AppColors.danger,
  );
  const radius = BorderRadius.all(Radius.circular(18));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.cream,
    fontFamily: 'sans-serif',
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.12,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.1,
        color: AppColors.ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: -.7,
        color: AppColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -.3,
        color: AppColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: AppColors.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: AppColors.muted),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.cream,
      foregroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: AppColors.ink,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        side: const BorderSide(color: AppColors.line),
        foregroundColor: AppColors.ink,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.mint,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? AppColors.primaryDark
              : AppColors.muted,
        ),
      ),
    ),
  );
}
