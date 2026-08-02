import 'package:flutter/material.dart';

abstract final class AppColors {
  static const paper = Color(0xFFF2EDE4);
  static const paperCard = Color(0xFFFAF7EF);
  static const ink = Color(0xFF16151A);
  static const bamboo = Color(0xFF3F5B4E);
  static const bambooSoft = Color(0xFFE4E9E3);
  static const seal = Color(0xFFC1442D);
  static const graphite = Color(0xFF6B655C);
  static const line = Color(0xFFE5DFD2);
  static const eye = Color(0xFFEAEFE1);
  static const eyeInk = Color(0xFF37402F);
}

ThemeData buildAppTheme({required Brightness brightness, Color? canvas}) {
  final dark = brightness == Brightness.dark;
  final background =
      canvas ?? (dark ? const Color(0xFF1B1A17) : AppColors.paper);
  final foreground = dark ? const Color(0xFFD8D0BE) : AppColors.ink;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.bamboo,
    brightness: brightness,
    surface: background,
    primary: AppColors.bamboo,
    secondary: AppColors.seal,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    fontFamily: 'serif',
    textTheme: ThemeData(
      brightness: brightness,
    ).textTheme.apply(bodyColor: foreground, displayColor: foreground),
    dividerColor: dark ? Colors.white12 : AppColors.line,
    cardColor: dark ? const Color(0xFF26231F) : AppColors.paperCard,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: foreground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF211F1C) : AppColors.paperCard,
      indicatorColor: AppColors.bambooSoft,
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
    ),
  );
}
