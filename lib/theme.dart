import 'package:flutter/material.dart';

// Light theme for FemDrive, aligned with Material 3 and updated pages, using brand colors
final ThemeData femLightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFF28AB2), // Soft Rose
    primary: const Color(0xFFF28AB2), // Soft Rose
    secondary: const Color(0xFFC9A0DC), // Warm Lilac
    error: const Color(0xFFFF6B6B), // Soft Red
    surface: const Color(0xFFF5F3F7), // Lavender Mist
    onSurface: const Color(0xFF333333), // Dark text
    surfaceContainer: const Color(0xFFECE6F0), // Slightly darker Lavender Mist
  ),
  scaffoldBackgroundColor: const Color(0xFFF5F3F7), // Lavender Mist
  appBarTheme: AppBarTheme(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose
    foregroundColor: Colors.white,
    elevation: 0,
    centerTitle: true,
    titleTextStyle: const TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 20,
      color: Colors.white,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFFECE6F0), // Surface container
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    prefixIconColor: WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? Colors.grey
          : const Color(0xFFF28AB2), // Soft Rose
    ),
    labelStyle: TextStyle(
      color: WidgetStateColor.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? Colors.grey
            : const Color(0xFF333333),
      ),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFF28AB2), // Soft Rose
      foregroundColor: Colors.white,
      textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      minimumSize: const Size(double.infinity, 48), // Full-width
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFFF28AB2), // Soft Rose
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
  ),
  cardTheme: CardThemeData(
    elevation: 2,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    color: Colors.white,
  ),
  floatingActionButtonTheme: FloatingActionButtonThemeData(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose
    foregroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose for success
    actionTextColor: Colors.white,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: const Color(0xFFF28AB2), // Soft Rose
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
    ),
    iconTheme: WidgetStateProperty.all(
      const IconThemeData(color: Color(0xFF333333)),
    ),
  ),
  textTheme: TextTheme(
    bodyMedium: const TextStyle(color: Color(0xFF333333)),
    titleLarge: const TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 24,
      color: Color(0xFF333333),
    ),
    titleMedium: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 16,
      color: Color(0xFF333333),
    ),
    labelLarge: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 14,
      color: Color(0xFFF28AB2), // Soft Rose
    ),
  ),
  dividerTheme: DividerThemeData(
    color: const Color(0xFFECE6F0), // Surface container
    thickness: 1,
  ),
);

// Dark theme for FemDrive, aligned with Material 3
final ThemeData femDarkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFF28AB2), // Soft Rose
    brightness: Brightness.dark,
    primary: const Color(0xFFF28AB2), // Soft Rose
    secondary: const Color(0xFFC9A0DC), // Warm Lilac
    error: const Color(0xFFFF6B6B), // Soft Red
    surface: const Color(0xFF1A1A1A), // Dark surface
    onSurface: Colors.white,
    surfaceContainer: const Color(0xFF2A2A2A), // Dark container
  ),
  scaffoldBackgroundColor: const Color(0xFF1A1A1A), // Dark surface
  appBarTheme: AppBarTheme(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose
    foregroundColor: Colors.white,
    elevation: 0,
    centerTitle: true,
    titleTextStyle: const TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 20,
      color: Colors.white,
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF2A2A2A), // Dark container
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    prefixIconColor: WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? Colors.grey
          : const Color(0xFFF28AB2), // Soft Rose
    ),
    labelStyle: TextStyle(
      color: WidgetStateColor.resolveWith(
        (states) =>
            states.contains(WidgetState.disabled) ? Colors.grey : Colors.white,
      ),
    ),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFF28AB2), // Soft Rose
      foregroundColor: Colors.white,
      textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      minimumSize: const Size(double.infinity, 48), // Full-width
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFFF28AB2), // Soft Rose
      textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
    ),
  ),
  cardTheme: CardThemeData(
    elevation: 2,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    color: const Color(0xFF2A2A2A), // Dark container
  ),
  floatingActionButtonTheme: FloatingActionButtonThemeData(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose
    foregroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: const Color(0xFFF28AB2), // Soft Rose for success
    actionTextColor: Colors.white,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
  navigationBarTheme: NavigationBarThemeData(
    backgroundColor: const Color(0xFF2A2A2A), // Dark container
    indicatorColor: const Color(0xFFF28AB2), // Soft Rose
    labelTextStyle: WidgetStateProperty.all(
      const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 12,
        color: Colors.white,
      ),
    ),
    iconTheme: WidgetStateProperty.all(
      const IconThemeData(color: Colors.white),
    ),
  ),
  textTheme: TextTheme(
    bodyMedium: const TextStyle(color: Colors.white),
    titleLarge: const TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 24,
      color: Colors.white,
    ),
    titleMedium: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 16,
      color: Colors.white,
    ),
    labelLarge: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 14,
      color: Color(0xFFF28AB2), // Soft Rose
    ),
  ),
  dividerTheme: DividerThemeData(
    color: const Color(0xFF2A2A2A), // Dark container
    thickness: 1,
  ),
);
