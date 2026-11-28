/// Bounded read of HTTP error response body (Hermes parity: `agent/
/// bounded_response.py`). Pada respons streaming non-OK, body dibaca hanya
/// untuk diagnostik (selalu ditruncate sebelum ditampilkan). Pembacaan polos
/// tidak berbatas dua arah: body bisa sangat besar (memori) atau stall
/// selamanya (hang). Fungsi ini membatasi jumlah byte dan menerapkan hard
/// deadline wall-clock; melewati batas, koneksi dibatalkan dan byte parsial
/// tetap dipertahankan. Never-raises: error transport menghasilkan teks
/// parsial (atau kosong) agar error baca tidak menutupi failure asli.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Nyaman untuk envelope error provider sungguhan, menolak body patologis.
const int defaultErrorBodyMaxBytes = 64 * 1024;

/// Hard deadline seluruh pembacaan; lewat itu koneksi dibatalkan dan byte
/// parsial dipertahankan.
const Duration defaultErrorBodyTimeout = Duration(seconds: 10);

/// Baca body streaming non-OK dengan batas byte dan deadline keras.
Future<String> readStreamedErrorBody(
  http.StreamedResponse response, {
  int maxBytes = defaultErrorBodyMaxBytes,
  Duration timeout = defaultErrorBodyTimeout,
}) async {
  final chunks = BytesBuilder(copy: false);
  var total = 0;
  var finished = false;
  final completer = Completer<void>();
  StreamSubscription<List<int>>? sub;

  void settle() {
    if (!completer.isCompleted) completer.complete();
  }

  try {
    sub = response.stream.listen(
      (chunk) {
        if (finished) return;
        if (chunk.isEmpty) return;
        final remaining = maxBytes - total;
        if (chunk.length > remaining) {
          if (remaining > 0) chunks.add(chunk.sublist(0, remaining));
          finished = true;
          settle();
          sub?.cancel().catchError((_) {});
          return;
        }
        chunks.add(chunk);
        total += chunk.length;
      },
      onError: (Object _) => settle(),
      onDone: settle,
      cancelOnError: false,
    );
  } catch (_) {
    return utf8.decode(chunks.takeBytes(), allowMalformed: true);
  }

  try {
    await completer.future.timeout(
      timeout,
      onTimeout: () async {
        finished = true;
        try {
          await sub?.cancel();
        } catch (_) {} // best-effort
      },
    );
  } catch (_) {
    // Never-raises: gagalan timeout internal tetap mengembalikan parsial.
  }

  return utf8.decode(chunks.takeBytes(), allowMalformed: true);
}
