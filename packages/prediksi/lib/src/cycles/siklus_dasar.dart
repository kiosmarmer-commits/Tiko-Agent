import '../core/models.dart';

/// Metode siklus tidak memerlukan data harga, cukup tanggal.
abstract class MetodeSiklus {
  String get nama;

  /// Hasilkan sinyal untuk [tanggal].
  Sinyal pada(DateTime tanggal);
}

/// Ubah tanggal menjadi tahun desimal, contoh 1 Juli 2026 -> sekitar 2026.5.
double tahunDesimal(DateTime t) {
  final u = t.toUtc();
  final awal = DateTime.utc(u.year);
  final akhir = DateTime.utc(u.year + 1);
  final frac = u.difference(awal).inMilliseconds /
      akhir.difference(awal).inMilliseconds;
  return u.year + frac;
}
