import 'dart:math' as math;

import '../core/math_utils.dart';

/// Kumpulan fungsi manajemen risiko. Menurut banyak praktisi, bagian inilah
/// yang paling menentukan hasil jangka panjang, bukan ketepatan prediksi.
class ManajemenRisiko {
  ManajemenRisiko._();

  /// Jumlah unit yang boleh dibeli agar kerugian bila kena stop = [risikoPersen]
  /// dari [modal]. Dibatasi agar nilai posisi tidak melebihi [maksFraksiModal]
  /// kali modal (default 1.0 = tanpa leverage).
  static double ukuranPosisi({
    required double modal,
    required double risikoPersen,
    required double hargaMasuk,
    required double hargaStop,
    double maksFraksiModal = 1.0,
  }) {
    final jarak = (hargaMasuk - hargaStop).abs();
    if (jarak == 0) {
      throw ArgumentError('hargaStop tidak boleh sama dengan hargaMasuk');
    }
    final unitRisiko = modal * (risikoPersen / 100) / jarak;
    final unitMaks = modal * maksFraksiModal / hargaMasuk;
    return math.min(unitRisiko, unitMaks);
  }

  /// Harga stop loss berbasis ATR: [kelipatan] x ATR dari harga masuk.
  static double stopLossAtr({
    required double hargaMasuk,
    required double atr,
    double kelipatan = 2,
    bool posisiLong = true,
  }) =>
      posisiLong ? hargaMasuk - kelipatan * atr : hargaMasuk + kelipatan * atr;

  /// Rasio imbalan terhadap risiko: jarak ke target dibagi jarak ke stop.
  static double rasioRisikoImbalan({
    required double hargaMasuk,
    required double hargaStop,
    required double hargaTarget,
  }) {
    final risiko = (hargaMasuk - hargaStop).abs();
    if (risiko == 0) throw ArgumentError('hargaStop tidak boleh sama dengan hargaMasuk');
    return (hargaTarget - hargaMasuk).abs() / risiko;
  }

  /// Kriteria Kelly: fraksi modal optimal = p - (1-p)/b, minimal 0.
  /// [rasioMenangKalah] = rata-rata keuntungan / rata-rata kerugian.
  /// Kelly penuh sangat agresif; pakai [kellyFraksi] (mis. setengah Kelly).
  static double kelly({
    required double peluangMenang,
    required double rasioMenangKalah,
  }) {
    if (rasioMenangKalah <= 0) return 0;
    return math.max(
      0.0,
      peluangMenang - (1 - peluangMenang) / rasioMenangKalah,
    );
  }

  static double kellyFraksi({
    required double peluangMenang,
    required double rasioMenangKalah,
    double fraksi = 0.5,
  }) =>
      kelly(peluangMenang: peluangMenang, rasioMenangKalah: rasioMenangKalah) *
      fraksi;

  /// Value at Risk historis: kerugian (proporsi, >= 0) yang hanya dilampaui
  /// dengan peluang (1 - [level]) berdasarkan [returns] historis.
  static double valueAtRisk(List<double> returns, {double level = 0.95}) {
    if (returns.isEmpty) return 0;
    return math.max(0.0, -MathUtils.persentil(returns, (1 - level) * 100));
  }

  /// Expected shortfall (CVaR): rata-rata kerugian pada ekor terburuk.
  static double expectedShortfall(List<double> returns, {double level = 0.95}) {
    if (returns.isEmpty) return 0;
    final batas = MathUtils.persentil(returns, (1 - level) * 100);
    final ekor = returns.where((r) => r <= batas).toList();
    if (ekor.isEmpty) return 0;
    return math.max(0.0, -MathUtils.rata(ekor));
  }

  /// Penurunan maksimum dari puncak (proporsi 0..1) pada kurva ekuitas.
  static double maxDrawdown(List<double> ekuitas) {
    var puncak = double.negativeInfinity;
    var terburuk = 0.0;
    for (final e in ekuitas) {
      if (e > puncak) puncak = e;
      if (puncak > 0) {
        final dd = (puncak - e) / puncak;
        if (dd > terburuk) terburuk = dd;
      }
    }
    return terburuk;
  }

  /// Sharpe ratio tahunan dari return per periode.
  static double sharpe(
    List<double> returns, {
    double bebasRisikoPerPeriode = 0,
    int periodePerTahun = 252,
  }) {
    if (returns.length < 2) return 0;
    final lebih = [for (final r in returns) r - bebasRisikoPerPeriode];
    final sd = MathUtils.stdDev(lebih);
    if (sd == 0 || sd.isNaN) return 0;
    return MathUtils.rata(lebih) / sd * math.sqrt(periodePerTahun);
  }

  /// Sortino ratio tahunan (hanya menghukum volatilitas ke bawah).
  static double sortino(
    List<double> returns, {
    double bebasRisikoPerPeriode = 0,
    int periodePerTahun = 252,
  }) {
    if (returns.length < 2) return 0;
    final lebih = [for (final r in returns) r - bebasRisikoPerPeriode];
    var s = 0.0;
    for (final r in lebih) {
      if (r < 0) s += r * r;
    }
    final dd = math.sqrt(s / lebih.length);
    if (dd == 0) return 0;
    return MathUtils.rata(lebih) / dd * math.sqrt(periodePerTahun);
  }
}
