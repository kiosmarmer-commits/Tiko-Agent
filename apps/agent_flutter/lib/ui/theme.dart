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

  // Extended surface states (GUI-P0-01): raised cards, hover/selected rows
  // and the modal scrim.
  static const surfaceRaised = Color(0xFF1C2028);
  static const surfaceHover = Color(0xFF232833);
  static const surfaceSelected = Color(0xFF2A3140);
  static const surfaceOverlay = Color(0x99000000);

  // Status colours beyond warning/danger.
  static const success = Color(0xFF57B48A);
  static const info = Color(0xFF5B9BD5);

  // Light palette.
  static const bgLight = Color(0xFFF5F6F8);
  static const panelLight = Color(0xFFFFFFFF);
  static const userBubbleLight = Color(0xFFD7ECF5);
  static const botBubbleLight = Color(0xFFECEEF1);
  static const borderLight = Color(0xFFD8DCE2);
  static const mutedLight = Color(0xFF5F6672);
  static const warnLight = Color(0xFF9C6F08);
  static const dangerLight = Color(0xFFB23A24);

  // Extended surface states, light variant.
  static const surfaceRaisedLight = Color(0xFFFAFBFC);
  static const surfaceHoverLight = Color(0xFFEDF0F3);
  static const surfaceSelectedLight = Color(0xFFDCE7F0);
  static const surfaceOverlayLight = Color(0x66000000);

  // Status colours, light variant.
  static const successLight = Color(0xFF1E7A4F);
  static const infoLight = Color(0xFF2264A5);

  // Spacing scale.
  static const s = 4.0;
  static const m = 8.0;
  static const l = 12.0;
  static const xl = 16.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;

  // Radius scale.
  static const radiusSmall = 8.0;
  static const radius = 12.0;
  static const radiusLarge = 16.0;

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

  static Color raised(Brightness brightness) =>
      brightness == Brightness.dark ? surfaceRaised : surfaceRaisedLight;

  static Color hover(Brightness brightness) =>
      brightness == Brightness.dark ? surfaceHover : surfaceHoverLight;

  static Color selected(Brightness brightness) =>
      brightness == Brightness.dark ? surfaceSelected : surfaceSelectedLight;

  static Color overlay(Brightness brightness) =>
      brightness == Brightness.dark ? surfaceOverlay : surfaceOverlayLight;

  static Color successColor(Brightness brightness) =>
      brightness == Brightness.dark ? success : successLight;

  static Color infoColor(Brightness brightness) =>
      brightness == Brightness.dark ? info : infoLight;

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

  // Typography scale (GUI-P0-01): colour inherits from the ambient
  // DefaultTextStyle so light/dark stay consistent.
  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  static const TextStyle pageTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const TextStyle body = TextStyle(fontSize: 14, height: 1.4);
  static const TextStyle caption = TextStyle(fontSize: 12, height: 1.3);
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
  Color get simpulSurfaceRaised =>
      SimpulTheme.raised(Theme.of(this).brightness);
  Color get simpulSurfaceHover =>
      SimpulTheme.hover(Theme.of(this).brightness);
  Color get simpulSurfaceSelected =>
      SimpulTheme.selected(Theme.of(this).brightness);
  Color get simpulSurfaceOverlay =>
      SimpulTheme.overlay(Theme.of(this).brightness);
  Color get simpulSuccess =>
      SimpulTheme.successColor(Theme.of(this).brightness);
  Color get simpulInfo => SimpulTheme.infoColor(Theme.of(this).brightness);
}
