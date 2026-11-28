// Hermes parity: `agent/estop.py` — emergency stop global yang RESUMABLE
// untuk pekerjaan BARU saja.
//
// Menulis sentinel `ESTOP` di direktori data runtime; selama sentinel ada,
// turn baru ditolak dengan pesan jelas (scheduler/gateway memeriksa sebelum
// menerima pekerjaan). Pekerjaan in-flight TIDAK pernah dibunuh — ini jeda,
// bukan kill switch. Body sentinel opsional JSON `{"reason", "engaged_at"}`;
// file kosong/korup tetap dihitung engaged (fail safe, mis. `touch ESTOP`).
// Port dari gastownhall/gastown estop.go (MIT) via Hermes.

import 'dart:convert';
import 'dart:io';

/// Nama file sentinel.
const estopSentinelName = 'ESTOP';

/// Global emergency stop berbasis sentinel file.
class Estop {
  Estop(this.directory);

  /// Direktori tempat sentinel ditulis (mis. dataDir runtime).
  final String directory;

  String get path => '$directory${directory.endsWith('/') ? '' : '/'}'
      '$estopSentinelName';

  /// True bila sentinel ada; error stat diperlakukan ENGAGED (fail safe,
  /// semangat Hermes: lebih aman menolak pekerjaan daripada salah jalan).
  bool isEngaged() {
    try {
      return File(path).existsSync();
    } catch (_) {
      return true;
    }
  }

  /// Buat sentinel. Idempotent; engage ulang memperbarui isi file.
  void engage([String? reason]) {
    final payload = {
      'engaged_at': DateTime.now().toUtc().toIso8601String(),
      'reason': (reason == null || reason.isEmpty) ? null : reason,
    };
    Directory(directory).createSync(recursive: true);
    File(path).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
    );
  }

  /// Baca payload sentinel; null bila tidak ada/korup (korup tetap engaged,
  /// hanya tidak ada metadata yang bisa dibaca).
  Map<String, dynamic>? readPayload() {
    try {
      final raw = File(path).readAsStringSync();
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Hapus sentinel. Idempotent: menghapus yang tidak ada bukan error.
  void release() {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {} // best-effort: never-raises; isEngaged() yang jadi sumber kebenaran
  }
}
