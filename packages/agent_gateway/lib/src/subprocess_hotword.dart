import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hotword.dart';

/// Detektor hotword konkret via proses eksternal (FR-08): detector CLI apa
/// pun (openWakeWord, vosk-streamer, skrip kustom) yang mencetak satu baris
/// non-kosong ke stdout tiap kali wake word terdeteksi.
///
/// Ini mengisi celah antara interface [HotwordListener] yang platform-agnostic
/// dan engine native (Porcupine/openWakeWord) yang butuh binding asli: tanpa
/// dependensi Dart baru, user bisa memasangkan detektor apa pun yang tersedia
/// di host. Fail-closed: proses yang gagal spawn atau mati tidak pernah
/// memicu deteksi palsu.
class SubprocessHotwordListener implements HotwordListener {
  SubprocessHotwordListener({
    required this.command,
    this.workingDirectory,
    this.environment,
    this.exitGrace = const Duration(seconds: 2),
  });

  /// Argv proses detektor, mis. `['python3', 'openwakeword_test.py']`.
  final List<String> command;

  final String? workingDirectory;

  /// Env tambahan untuk proses (mis. path model atau device audio).
  final Map<String, String>? environment;

  /// Tenggang waktu tunggu exit saat stop() sebelum kill dipaksa.
  final Duration exitGrace;

  Process? _process;
  void Function()? _onDetected;
  bool _listening = false;

  /// Proses detektor yang sedang berjalan, kalau ada.
  Process? get process => _process;

  @override
  String get name => 'subprocess:${command.first}';

  @override
  bool get isListening => _listening;

  @override
  Future<void> start(void Function() onDetected) async {
    if (command.isEmpty) {
      throw ArgumentError('command tidak boleh kosong');
    }
    if (_listening) {
      _onDetected = onDetected;
      return;
    }
    final process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
    );
    _process = process;
    _onDetected = onDetected;
    _listening = true;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      _onDetected?.call();
    }, onError: (_) {});
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {}, onError: (_) {});
    unawaited(
      process.exitCode.then((_) {
        _listening = false;
        _process = null;
      }),
    );
  }

  @override
  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      _listening = false;
      _onDetected = null;
      return;
    }
    process.kill();
    try {
      await process.exitCode.timeout(exitGrace);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    _process = null;
    _listening = false;
    _onDetected = null;
  }
}
