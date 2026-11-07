import 'dart:async';

/// FR-08 (Hotword "Hey Tiko"): platform hook for an always-on wake-word
/// listener.
///
/// Wake-word detection is inherently platform-specific (Porcupine,
/// openWakeWord, Android SpeechService, etc.). This interface keeps the
/// gateway engine platform-agnostic; concrete implementations live in the
/// Flutter app (platform channels) or CLI (subprocess + FIFO).
abstract class HotwordListener {
  /// Human-readable listener name (for logs/diagnostics).
  String get name;

  /// True when the listener is currently capturing audio.
  bool get isListening;

  /// Starts listening; [onDetected] fires on every wake-word detection.
  /// Implementations must be idempotent: calling start() twice must not
  /// double-register callbacks.
  Future<void> start(void Function() onDetected);

  /// Stops listening and releases platform resources (mic, DSP session).
  Future<void> stop();
}

/// Always-available no-op listener. Keeps the voice pipeline runnable on
/// platforms without a detector; [onDetected] simply never fires.
class NoopHotwordListener implements HotwordListener {
  @override
  String get name => 'noop';

  @override
  bool get isListening => false;

  @override
  Future<void> start(void Function() onDetected) async {}

  @override
  Future<void> stop() async {}
}

/// Simple push-to-talk fallback: the UI/CLI layer calls [trigger] when the
/// user presses a hotkey or taps a mic button.
class PushToTalkHotwordListener implements HotwordListener {
  PushToTalkHotwordListener();

  void Function()? _onDetected;

  @override
  String get name => 'push-to-talk';

  @override
  bool get isListening => _onDetected != null;

  @override
  Future<void> start(void Function() onDetected) async {
    _onDetected = onDetected;
  }

  @override
  Future<void> stop() async {
    _onDetected = null;
  }

  /// Fire the registered detection callback (no-op when not started).
  void trigger() => _onDetected?.call();
}
