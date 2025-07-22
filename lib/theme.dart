import 'package:flutter/material.dart';

final ThemeData femTheme = ThemeData(
  colorScheme: ColorScheme.light(
    primary: Color(0xFFF28AB2), // Soft Rose
    secondary: Color(0xFFC9A0DC), // Warm Lilac
    error: Color(0xFFFF6B6B), // Soft Red
  ),
  scaffoldBackgroundColor: Color(0xFFF5F3F7), // Lavender Mist
  appBarTheme: AppBarTheme(
    backgroundColor: Color(0xFFF28AB2),
    foregroundColor: Colors.white,
    elevation: 0,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: Color(0xFFF28AB2),
      foregroundColor: Colors.white,
      textStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      padding: EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  textTheme: const TextTheme(bodyMedium: TextStyle(color: Color(0xFF333333))),
);
