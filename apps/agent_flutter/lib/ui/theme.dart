import 'package:flutter/material.dart';

/// Central design tokens (UI-CON): every screen — desktop, web, Android —
/// draws its colours, spacing and text styles from here so the app looks
/// identical on all platforms.
abstract final class SimpulTheme {
  // Dark palette (default).
  static const bg = Color(0xFF0F1115);
  static const panel = Color(0xFF171A21);
  static const accent = Color(0xFF2A9D8F);
  static const userBubble = Color(0xFF1B3A4B);
  static const botBubble = Color(0xFF1E2430);
  static const border = Color(0xFF2A2F3A);
  static const muted = Color(0xFF9AA0A6);
  static const warn = Color(0xFFE9C46A);
  static const danger = Color(0xFFE76F51);

  // Light palette.
  static const bgLight = Color(0xFFF5F6F8);
  static const panelLight = Color(0xFFFFFFFF);
  static const userBubbleLight = Color(0xFFD7ECF5);
  static const botBubbleLight = Color(0xFFECEEF1);
  static const borderLight = Color(0xFFD8DCE2);
  static const mutedLight = Color(0xFF5F6672);
  static const warnLight = Color(0xFF9C6F08);
  static const dangerLight = Color(0xFFB23A24);

  // Spacing scale.
  static const s = 4.0;
  static const m = 8.0;
  static const l = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;

  static const radius = 12.0;

  static Color surface(Brightness brightness) =>
      brightness == Brightness.dark ? panel : panelLight;

  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? bg : bgLight;

  static Color outline(Brightness brightness) =>
      brightness == Brightness.dark ? border : borderLight;

  static Color mutedText(Brightness brightness) =>
      brightness == Brightness.dark ? muted : mutedLight;

  static Color bubble(Brightness brightness, {required bool user}) =>
      brightness == Brightness.dark
          ? (user ? userBubble : botBubble)
          : (user ? userBubbleLight : botBubbleLight);

  static Color warning(Brightness brightness) =>
      brightness == Brightness.dark ? warn : warnLight;

  static Color dangerColor(Brightness brightness) =>
      brightness == Brightness.dark ? danger : dangerLight;

  static ThemeData theme(Brightness brightness, Color accentColor) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: brightness,
    ).copyWith(
      primary: accentColor,
      surface: surface(brightness),
    );
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: background(brightness),
      colorScheme: scheme,
      dividerColor: outline(brightness),
      useMaterial3: true,
    );
  }

  static BoxDecoration panelBox(Brightness brightness) => BoxDecoration(
        color: surface(brightness),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: outline(brightness)),
      );
}

/// Brightness-aware colour access for widgets: `context.panel` etc. resolve
/// against the current [ThemeData] so light and dark modes stay consistent.
extension SimpulThemeContext on BuildContext {
  Color get simpulBg => SimpulTheme.background(Theme.of(this).brightness);
  Color get simpulPanel => SimpulTheme.surface(Theme.of(this).brightness);
  Color get simpulAccent => Theme.of(this).colorScheme.primary;
  Color get simpulUserBubble =>
      SimpulTheme.bubble(Theme.of(this).brightness, user: true);
  Color get simpulBotBubble =>
      SimpulTheme.bubble(Theme.of(this).brightness, user: false);
  Color get simpulBorder => SimpulTheme.outline(Theme.of(this).brightness);
  Color get simpulMuted => SimpulTheme.mutedText(Theme.of(this).brightness);
  Color get simpulWarn => SimpulTheme.warning(Theme.of(this).brightness);
  Color get simpulDanger => SimpulTheme.dangerColor(Theme.of(this).brightness);
}
