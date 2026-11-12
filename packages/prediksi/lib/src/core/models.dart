// Model data inti yang dipakai semua metode.

/// Satu candle harga (Open, High, Low, Close, Volume).
class Candle {
  final DateTime waktu;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;

  const Candle({
    required this.waktu,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume = 0,
  });

  @override
  String toString() => 'Candle($waktu, O:$open H:$high L:$low C:$close V:$volume)';
}

/// Arah sinyal yang dihasilkan sebuah metode.
enum Arah { beli, jual, tahan }

/// Hasil standar dari sebuah metode prediksi.
///
/// [skor] berkisar -1.0 (sangat bearish) sampai +1.0 (sangat bullish).
/// [metode] adalah nama metode, [catatan] penjelasan singkat.
class Sinyal {
  final String metode;
  final Arah arah;
  final double skor;
  final String catatan;

  const Sinyal({
    required this.metode,
    required this.arah,
    required this.skor,
    this.catatan = '',
  });

  /// Buat sinyal dari skor: > [ambang] beli, < -[ambang] jual, selain itu tahan.
  factory Sinyal.dariSkor(
    String metode,
    double skor, {
    double ambang = 0.25,
    String catatan = '',
  }) {
    final s = skor.clamp(-1.0, 1.0).toDouble();
    final arah = s > ambang
        ? Arah.beli
        : (s < -ambang ? Arah.jual : Arah.tahan);
    return Sinyal(metode: metode, arah: arah, skor: s, catatan: catatan);
  }

  @override
  String toString() =>
      'Sinyal($metode, ${arah.name}, skor: ${skor.toStringAsFixed(2)}) $catatan';
}

/// Antarmuka umum: setiap metode berbasis candle bisa dipakai seragam.
abstract class MetodePrediksi {
  String get nama;
  Sinyal analisis(List<Candle> data);
}
