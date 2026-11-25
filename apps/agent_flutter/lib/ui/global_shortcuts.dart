import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shortcut keyboard global (Codex item 11) yang berlaku konsisten di
/// seluruh halaman:
/// - `Ctrl/Cmd+K` dan `Ctrl/Cmd+P` : buka command palette
/// - `Ctrl/Cmd+N`                  : sesi/chat baru
/// - `Ctrl/Cmd+H`                  : buka history sesi
/// - `Ctrl/Cmd+Alt+ArrowUp/Down`   : pindah ke sesi sebelumnya/berikutnya
/// Shortcut spesifik panel `Ctrl/Cmd+Enter` (kirim) dan `Esc` (tutup panel)
/// di-wire di composer/pane terkait. Callback null tidak dipasang — halaman
/// tanpa fitur terkait mengabaikan shortcut. Bindings selalu dipasang untuk
/// `control` dan `meta` agar Ctrl (Windows/Linux) dan Cmd (macOS) setara.
class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({
    super.key,
    required this.onPalette,
    this.onNewChat,
    this.onOpenHistory,
    this.onPreviousSession,
    this.onNextSession,
    this.onEscape,
    required this.child,
  });

  final VoidCallback onPalette;
  final VoidCallback? onNewChat;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onPreviousSession;
  final VoidCallback? onNextSession;

  /// `Esc` global: menutup panel terbuka (preview artifact, inspector).
  /// Aman untuk dialog — fokus di dalam dialog tidak melewati subtree ini.
  final VoidCallback? onEscape;
  final Widget child;

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.keyK, control: true): onPalette,
    const SingleActivator(LogicalKeyboardKey.keyK, meta: true): onPalette,
    const SingleActivator(LogicalKeyboardKey.keyP, control: true): onPalette,
    const SingleActivator(LogicalKeyboardKey.keyP, meta: true): onPalette,
    if (onNewChat != null) ...{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): onNewChat!,
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): onNewChat!,
    },
    if (onOpenHistory != null) ...{
      const SingleActivator(LogicalKeyboardKey.keyH, control: true):
          onOpenHistory!,
      const SingleActivator(LogicalKeyboardKey.keyH, meta: true):
          onOpenHistory!,
    },
    if (onPreviousSession != null) ...{
      const SingleActivator(
        LogicalKeyboardKey.arrowUp,
        alt: true,
        control: true,
      ): onPreviousSession!,
      const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true, meta: true):
          onPreviousSession!,
    },
    if (onNextSession != null) ...{
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        alt: true,
        control: true,
      ): onNextSession!,
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        alt: true,
        meta: true,
      ): onNextSession!,
    },
    if (onEscape != null)
      const SingleActivator(LogicalKeyboardKey.escape): onEscape!,
  };

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _bindings,
      child: Focus(autofocus: true, child: child),
    );
  }
}
