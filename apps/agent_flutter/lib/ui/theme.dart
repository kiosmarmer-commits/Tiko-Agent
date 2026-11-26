import 'package:flutter/material.dart';

/// Shared Tiko design tokens for web and responsive Flutter surfaces.
abstract final class TikoTheme {
  // Layout breakpoints shared by the app shell and feature panels.
  static const desktopBreakpoint = 1100.0;
  static const multiPaneBreakpoint = 1360.0;
  static const wideGridBreakpoint = 720.0;
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
  static const radiusPill = 24.0;

  // High-contrast body text (flat design keeps hierarchy on surfaces).
  static const textHigh = Color(0xFFE6E8EB);
  static const textHighLight = Color(0xFF1A1D23);

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

  static Color bodyText(Brightness brightness) =>
      brightness == Brightness.dark ? textHigh : textHighLight;

  static TextTheme textTheme(Brightness brightness) => const TextTheme(
    titleLarge: pageTitle,
    titleMedium: sectionTitle,
    bodyMedium: body,
    bodySmall: caption,
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  ).apply(bodyColor: bodyText(brightness), displayColor: bodyText(brightness));

  static OutlineInputBorder _inputBorder(
    Brightness brightness, {
    Color? color,
    double width = 1,
  }) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(radius),
    borderSide: BorderSide(color: color ?? outline(brightness), width: width),
  );

  static ThemeData theme(Brightness brightness, Color accentColor) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: brightness,
        ).copyWith(
          primary: accentColor,
          surface: surface(brightness),
          outline: outline(brightness),
          outlineVariant: outline(brightness),
          onSurface: bodyText(brightness),
          onSurfaceVariant: mutedText(brightness),
        );
    final border = outline(brightness);
    final onSelect = selected(brightness);
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: background(brightness),
      colorScheme: scheme,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      useMaterial3: true,
      splashFactory: InkSparkle.splashFactory,
      textTheme: textTheme(brightness),
      iconTheme: IconThemeData(color: mutedText(brightness)),
      appBarTheme: AppBarTheme(
        backgroundColor: background(brightness),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: pageTitle.copyWith(color: bodyText(brightness)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: surface(brightness),
        indicatorColor: selected(brightness),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? accentColor
                : mutedText(brightness),
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? accentColor
                : mutedText(brightness),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: accentColor,
        selectedTileColor: selected(brightness),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: raised(brightness),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: BorderSide(color: border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: raised(brightness),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: BorderSide(color: border),
        ),
        titleTextStyle: pageTitle.copyWith(color: bodyText(brightness)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: brightness == Brightness.dark
            ? surfaceHover
            : surfaceHoverLight,
        contentTextStyle: body.copyWith(color: bodyText(brightness)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? surfaceHover
            : surfaceHoverLight,
        hintStyle: TextStyle(color: mutedText(brightness)),
        helperStyle: TextStyle(color: mutedText(brightness)),
        contentPadding: const EdgeInsets.symmetric(horizontal: xl, vertical: l),
        border: _inputBorder(brightness),
        enabledBorder: _inputBorder(brightness),
        focusedBorder: _inputBorder(brightness, color: accentColor, width: 1.5),
        errorBorder: _inputBorder(brightness, color: dangerColor(brightness)),
        focusedErrorBorder: _inputBorder(
          brightness,
          color: dangerColor(brightness),
          width: 1.5,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: raised(brightness),
          foregroundColor: bodyText(brightness),
          elevation: 0,
          minimumSize: const Size(0, 40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: border),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: bodyText(brightness),
          minimumSize: const Size(0, 40),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        indicatorColor: onSelect,
        selectedIconTheme: IconThemeData(color: bodyText(brightness)),
        unselectedIconTheme: IconThemeData(color: mutedText(brightness)),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: bodyText(brightness),
        ),
        unselectedLabelTextStyle: TextStyle(
          color: mutedText(brightness),
          fontSize: 12,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised(brightness),
        side: BorderSide(color: border),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(color: bodyText(brightness), fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: l, vertical: 2),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised(brightness),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
        textStyle: TextStyle(color: bodyText(brightness), fontSize: 14),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: brightness == Brightness.dark
              ? surfaceHover
              : surfaceHoverLight,
          borderRadius: BorderRadius.circular(radiusSmall),
          border: Border.all(color: border),
        ),
        textStyle: TextStyle(color: bodyText(brightness), fontSize: 12),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: accentColor,
        unselectedLabelColor: mutedText(brightness),
        indicatorColor: accentColor,
        dividerColor: border,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accentColor,
        linearTrackColor: hover(brightness),
        circularTrackColor: hover(brightness),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(6),
        radius: const Radius.circular(radiusPill),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? mutedText(brightness)
              : border,
        ),
      ),
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

/// Compatibility alias for feature widgets that still use the historical
/// theme name. New code should use [TikoTheme].
typedef SimpulTheme = TikoTheme;

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
  Color get simpulSurfaceHover => SimpulTheme.hover(Theme.of(this).brightness);
  Color get simpulSurfaceSelected =>
      SimpulTheme.selected(Theme.of(this).brightness);
  Color get simpulSurfaceOverlay =>
      SimpulTheme.overlay(Theme.of(this).brightness);
  Color get simpulSuccess =>
      SimpulTheme.successColor(Theme.of(this).brightness);
  Color get simpulInfo => SimpulTheme.infoColor(Theme.of(this).brightness);
}
