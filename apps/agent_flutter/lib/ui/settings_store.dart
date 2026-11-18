import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// User preferences persisted locally (UI-SET): theme mode, accent colour,
/// and daemon/connection behaviour. Shared by the desktop, web and Android
/// shells so every platform renders identically.
class AppSettings {
  AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accent = SimpulTheme.accent,
    this.ollamaHost = 'http://127.0.0.1:11434',
    this.vaultPath = '',
    this.autoLockMinutes = 0,
    this.powerSaver = false,
    this.multiPane = false,
  });

  final ThemeMode themeMode;
  final Color accent;
  final String ollamaHost;
  final String vaultPath;
  final int autoLockMinutes;

  /// AI-U04: when enabled, embedding/LLM work only runs while the device
  /// is plugged in (unknown power state is treated as plugged).
  final bool powerSaver;

  /// GUI-P2-03: on wide screens, the chat workspace renders multi-pane
  /// (sessions pane + chat + inspector pane). Pure layout preference —
  /// the same routes and APIs stay available in single-pane mode.
  final bool multiPane;

  static const _kThemeMode = 'ui.themeMode';
  static const _kAccent = 'ui.accent';
  static const _kOllamaHost = 'ui.ollamaHost';
  static const _kVaultPath = 'ui.vaultPath';
  static const _kAutoLock = 'ui.autoLockMinutes';
  static const _kPowerSaver = 'ui.powerSaver';
  static const _kMultiPane = 'ui.multiPane';

  static const accents = [
    Color(0xFF2A9D8F),
    Color(0xFF4C8DFF),
    Color(0xFF9B6BFF),
    Color(0xFFE9803C),
    Color(0xFFE5537A),
  ];

  AppSettings copyWith({
    ThemeMode? themeMode,
    Color? accent,
    String? ollamaHost,
    String? vaultPath,
    int? autoLockMinutes,
    bool? powerSaver,
    bool? multiPane,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      ollamaHost: ollamaHost ?? this.ollamaHost,
      vaultPath: vaultPath ?? this.vaultPath,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
      powerSaver: powerSaver ?? this.powerSaver,
      multiPane: multiPane ?? this.multiPane,
    );
  }

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    Color accent = SimpulTheme.accent;
    final storedAccent = prefs.getInt(_kAccent);
    if (storedAccent != null) {
      final match = accents
          .where((c) => c.toARGB32() == storedAccent)
          .firstOrNull;
      if (match != null) accent = match;
    }
    return AppSettings(
      themeMode: switch (prefs.getString(_kThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      },
      accent: accent,
      ollamaHost: prefs.getString(_kOllamaHost) ?? 'http://127.0.0.1:11434',
      vaultPath: prefs.getString(_kVaultPath) ?? '',
      autoLockMinutes: prefs.getInt(_kAutoLock) ?? 0,
      powerSaver: prefs.getBool(_kPowerSaver) ?? false,
      multiPane: prefs.getBool(_kMultiPane) ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, themeMode.name);
    await prefs.setInt(_kAccent, accent.toARGB32());
    await prefs.setString(_kOllamaHost, ollamaHost);
    await prefs.setString(_kVaultPath, vaultPath);
    await prefs.setInt(_kAutoLock, autoLockMinutes);
    await prefs.setBool(_kPowerSaver, powerSaver);
    await prefs.setBool(_kMultiPane, multiPane);
  }
}
