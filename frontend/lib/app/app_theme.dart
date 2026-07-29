import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Product palette sampled from the final Memory Home boards.
abstract final class AppColors {
  static const ink = Color(0xFF33291F);
  static const inkSoft = Color(0xFF51473C);
  static const muted = Color(0xFF81766A);
  static const sage = Color(0xFFB8C38E);
  static const sageDark = Color(0xFF6E7F45);
  static const sageSoft = Color(0xFFF0F2DF);
  static const greenCard = Color(0xFFE4E8C8);
  static const yellow = Color(0xFFF3C36B);
  static const yellowSoft = Color(0xFFFFE8B7);
  static const coral = Color(0xFFF47B61);
  static const coralDark = Color(0xFFDF634C);
  static const coralSoft = Color(0xFFFFE3D9);
  static const pink = Color(0xFFF8DAD0);
  static const pinkSoft = Color(0xFFFFF0EA);
  static const cream = Color(0xFFFFFAF1);
  static const surface = Color(0xFFFFFDF8);
  static const surfaceWarm = Color(0xFFFFF7EA);
  static const line = Color(0xFFEDE2D3);
  static const danger = Color(0xFFD95F54);
  static const live = Color(0xFFFF665B);
  static const online = Color(0xFF789652);

  // Compatibility aliases used by existing feature widgets.
  static const primary = coral;
  static const primaryDark = coralDark;
  static const mint = sageSoft;
  static const peach = yellowSoft;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.coral,
    brightness: Brightness.light,
    primary: AppColors.coral,
    surface: AppColors.surface,
    error: AppColors.danger,
  );
  const radius = BorderRadius.all(Radius.circular(18));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.cream,
    fontFamily: 'NotoSansKR',
    fontFamilyFallback: const ['Noto Sans KR', 'sans-serif'],
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansKR',
        fontSize: 22,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: AppColors.ink,
      ),
    ),
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 37,
        height: 1.12,
        fontWeight: FontWeight.w900,
        letterSpacing: -1.8,
        color: AppColors.ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 1.18,
        fontWeight: FontWeight.w900,
        letterSpacing: -1.25,
        color: AppColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 21,
        height: 1.25,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.75,
        color: AppColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.35,
        color: AppColors.ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.25,
        color: AppColors.inkSoft,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.45,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.2,
        color: AppColors.muted,
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.25,
        color: AppColors.ink,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Color(0x170D0905),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
        side: BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      hintStyle: const TextStyle(color: AppColors.muted),
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.line, width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.coral, width: 1.7),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.coral,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.line,
        minimumSize: const Size.fromHeight(56),
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansKR',
          fontSize: 16,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        side: const BorderSide(color: AppColors.line, width: 1.2),
        foregroundColor: AppColors.inkSoft,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansKR',
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.coralDark,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      backgroundColor: AppColors.surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.coralSoft,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 27,
          color: states.contains(WidgetState.selected)
              ? AppColors.coral
              : AppColors.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'NotoSansKR',
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: states.contains(WidgetState.selected)
              ? AppColors.coralDark
              : AppColors.muted,
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.coral,
    ),
  );
}
