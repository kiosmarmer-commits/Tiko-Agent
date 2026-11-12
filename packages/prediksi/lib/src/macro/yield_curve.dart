import '../core/models.dart';

/// Analisis kurva imbal hasil (yield curve) dari spread tenor panjang dan pendek.
///
/// Inversi (tenor pendek lebih tinggi dari tenor panjang) secara historis
/// sering mendahului resesi dengan jeda sekitar 6-24 bulan, tetapi bukan
/// jaminan. Satuan input: persen (contoh 4.25 untuk 4,25%).
class YieldCurve {
  const YieldCurve();

  String get nama => 'Yield Curve';

  /// [hasilPanjang] misalnya obligasi 10 tahun, [hasilPendek] misalnya 2 tahun
  /// atau 3 bulan. [spreadSebelumnya] (opsional) mendeteksi kurva yang kembali
  /// menanjak setelah inversi.
  Sinyal sinyal({
    required double hasilPanjang,
    required double hasilPendek,
    double? spreadSebelumnya,
  }) {
    final spread = hasilPanjang - hasilPendek;
    final double skor;
    final String ket;

    if (spreadSebelumnya != null && spreadSebelumnya < 0 && spread >= 0) {
      skor = -0.3;
      ket = 'kembali menanjak setelah inversi (sering bersamaan dengan awal resesi)';
    } else if (spread <= -0.5) {
      skor = -0.9;
      ket = 'inversi dalam';
    } else if (spread < 0) {
      skor = -0.5;
      ket = 'inversi';
    } else if (spread < 0.5) {
      skor = 0.0;
      ket = 'datar';
    } else if (spread < 1.5) {
      skor = 0.3;
      ket = 'normal';
    } else {
      skor = 0.5;
      ket = 'curam (biasanya fase awal pemulihan)';
    }

    return Sinyal.dariSkor(
      nama,
      skor,
      catatan: 'Spread ${spread.toStringAsFixed(2)} poin persentase: $ket',
    );
  }
}
