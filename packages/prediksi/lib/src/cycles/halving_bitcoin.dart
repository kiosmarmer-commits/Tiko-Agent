import '../core/models.dart';
import 'siklus_dasar.dart';

/// Siklus empat tahunan Bitcoin berdasarkan jarak waktu sejak halving.
///
/// Pola historis (tidak ada jaminan akan berulang, sampelnya hanya beberapa
/// siklus): fase naik sampai ~12-18 bulan setelah halving, lalu koreksi/bear,
/// lalu akumulasi menjelang halving berikutnya.
class HalvingBitcoin implements MetodeSiklus {
  /// Tanggal halving (UTC), urut menaik. Tanggal terakhir bisa perkiraan.
  final List<DateTime> tanggalHalving;

  HalvingBitcoin({List<DateTime>? tanggal})
      : tanggalHalving = ([...(tanggal ?? _bawaan)]..sort());

  static final List<DateTime> _bawaan = [
    DateTime.utc(2012, 11, 28),
    DateTime.utc(2016, 7, 9),
    DateTime.utc(2020, 5, 11),
    DateTime.utc(2024, 4, 20),
    DateTime.utc(2028, 4, 1), // perkiraan
  ];

  @override
  String get nama => 'Halving Bitcoin';

  /// Jumlah bulan sejak halving terakhir sebelum [tanggal], atau null.
  double? bulanSejakHalving(DateTime tanggal) {
    DateTime? terakhir;
    for (final h in tanggalHalving) {
      if (!h.isAfter(tanggal.toUtc())) terakhir = h;
    }
    if (terakhir == null) return null;
    return tanggal.toUtc().difference(terakhir).inHours / 24 / 30.44;
  }

  @override
  Sinyal pada(DateTime tanggal) {
    final b = bulanSejakHalving(tanggal);
    if (b == null) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Sebelum halving pertama dalam daftar.',
      );
    }
    final (skor, fase) = switch (b) {
      < 6 => (0.4, 'pasca-halving awal'),
      < 12 => (0.6, 'fase naik'),
      < 18 => (-0.6, 'zona puncak historis'),
      < 30 => (-0.8, 'fase bear historis'),
      _ => (0.3, 'akumulasi menjelang halving berikutnya'),
    };
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan: '${b.toStringAsFixed(1)} bulan sejak halving: $fase',
    );
  }
}
