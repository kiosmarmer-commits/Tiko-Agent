import 'dart:async';
import 'dart:isolate';

import 'calc_engine.dart';
import 'core/errors.dart';
import 'core/limits.dart';
import 'core/result.dart';
import 'core/rounding.dart';

/// Eksekusi evaluasi di isolate terpisah dengan timeout yang dapat
/// membatalkan (TASK-CALC-09): saat melewati limits.timeoutMs isolat
/// dibunuh keras dan hasilnya galat CALC_E_TIMEOUT - tidak pernah
/// angka tebakan (P5). Untuk ekspresi biasa jalur sinkron
/// [CalcEngine] lebih murah; sandbox untuk beban besar yang butuh
/// pembatalan keras.
final class CalcSandbox {
  const CalcSandbox();

  /// Titik masuk isolat: evaluasi di dalam isolat lalu kirim hasil.
  static void _entry(List<Object> args) {
    final port = args[0] as SendPort;
    final engine = CalcEngine(limits: args[6] as CalcLimits);
    final result = engine.evaluate(
      args[1] as String,
      scale: args[2] as int,
      rounding: args[3] as RoundingMode,
      locale: args[4] as String,
      strict: args[5] as bool,
    );
    port.send(result);
  }

  /// Evaluasi terisolasi. Listener dipasang SEBELUM spawn agar hasil
  /// tidak hilang; isolat selalu dibunuh di finally (selesai maupun
  /// dibatalkan).
  Future<CalcResult> evaluate(
    String input, {
    int scale = 12,
    RoundingMode rounding = RoundingMode.halfEven,
    String locale = 'id',
    bool strict = false,
    CalcLimits limits = CalcLimits.defaults,
  }) async {
    final resultPort = ReceivePort();
    final exitPort = ReceivePort();
    final completer = Completer<Object?>();
    final resultSub = resultPort.listen(
      (m) {
        if (!completer.isCompleted) completer.complete(m);
      },
    );
    final exitSub = exitPort.listen(
      (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    final iso = await Isolate.spawn(
      _entry,
      [
        resultPort.sendPort,
        input,
        scale,
        rounding,
        locale,
        strict,
        limits,
      ],
      onExit: exitPort.sendPort,
      errorsAreFatal: true,
    );
    var timedOut = false;
    try {
      final msg = await completer.future.timeout(
        Duration(milliseconds: limits.timeoutMs),
        onTimeout: () {
          timedOut = true;
          return null;
        },
      );
      if (msg is CalcResult) return msg;
      if (!timedOut) return _crash();
    } finally {
      await resultSub.cancel();
      await exitSub.cancel();
      resultPort.close();
      exitPort.close();
      iso.kill(priority: Isolate.immediate);
    }
    return _timeout(limits.timeoutMs);
  }

  static CalcResult _timeout(int ms) {
    return _error(
      CalcErrorCodes.timeout,
      'Evaluasi dibatalkan: melewati batas waktu ($ms ms)',
    );
  }

  static CalcResult _crash() {
    return _error(
      CalcErrorCodes.syntax,
      'Evaluasi gagal di sandbox (galat internal)',
    );
  }

  static CalcResult _error(String code, String message) => CalcResult(
        ok: false,
        approximate: false,
        error: CalcException(code, message),
      );
}
