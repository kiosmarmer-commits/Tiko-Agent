import 'dart:math' as math;

import '../core/math_utils.dart';
import '../core/models.dart';

/// Data fundamental satu saham/perusahaan (per saham), diisi sendiri.
class DataFundamental {
  final double harga;
  final double labaPerSaham;
  final double nilaiBukuPerSaham;
  final double dividenPerSaham;

  /// Perkiraan pertumbuhan laba tahunan, dalam persen (10 = 10%).
  final double pertumbuhanLabaPersen;

  /// Return on equity dalam persen (opsional).
  final double? roePersen;

  /// Utang terhadap ekuitas, rasio (1.5 = 150%) (opsional).
  final double? utangPerEkuitas;

  const DataFundamental({
    required this.harga,
    required this.labaPerSaham,
    required this.nilaiBukuPerSaham,
    this.dividenPerSaham = 0,
    this.pertumbuhanLabaPersen = 0,
    this.roePersen,
    this.utangPerEkuitas,
  });

  /// Price to earnings; null jika laba tidak positif.
  double? get per => labaPerSaham > 0 ? harga / labaPerSaham : null;

  /// Price to book; null jika nilai buku tidak positif.
  double? get pbv => nilaiBukuPerSaham > 0 ? harga / nilaiBukuPerSaham : null;

  /// Imbal hasil dividen (proporsi, 0.04 = 4%).
  double get imbalDividen => harga > 0 ? dividenPerSaham / harga : 0;

  /// PEG: PER dibagi pertumbuhan laba; null jika tidak dapat dihitung.
  double? get peg {
    final p = per;
    return (p != null && pertumbuhanLabaPersen > 0)
        ? p / pertumbuhanLabaPersen
        : null;
  }
}

/// Valuasi fundamental dengan angka Graham, rumus pertumbuhan Graham, dan DCF.
///
/// Semua rumus adalah penyederhanaan. Hasilnya sangat sensitif terhadap
/// asumsi pertumbuhan dan diskonto, jadi pakai sebagai pembanding kasar.
class AnalisisFundamental {
  const AnalisisFundamental();

  String get nama => 'Analisis Fundamental';

  /// Angka Graham: sqrt(22.5 * EPS * BVPS).
  static double? angkaGraham(double eps, double bvps) =>
      (eps > 0 && bvps > 0) ? math.sqrt(22.5 * eps * bvps) : null;

  /// Rumus pertumbuhan Graham: EPS * (8.5 + 2g), g dibatasi 0..15 persen.
  static double? nilaiGraham(double eps, double pertumbuhanPersen) =>
      eps > 0 ? eps * (8.5 + 2 * pertumbuhanPersen.clamp(0.0, 15.0)) : null;

  /// DCF sederhana: arus kas bebas tumbuh [pertumbuhanPersen] selama [tahun],
  /// lalu nilai terminal dengan pertumbuhan [pertumbuhanTerminalPersen].
  /// Null jika diskonto <= pertumbuhan terminal.
  static double? dcf({
    required double arusKasAwal,
    required double pertumbuhanPersen,
    required double diskontoPersen,
    int tahun = 10,
    double pertumbuhanTerminalPersen = 2,
  }) {
    final g = pertumbuhanPersen / 100;
    final r = diskontoPersen / 100;
    final gt = pertumbuhanTerminalPersen / 100;
    if (r <= gt || tahun <= 0) return null;

    var total = 0.0;
    var arus = arusKasAwal;
    for (var t = 1; t <= tahun; t++) {
      arus *= 1 + g;
      total += arus / math.pow(1 + r, t);
    }
    final terminal = arus * (1 + gt) / (r - gt);
    return total + terminal / math.pow(1 + r, tahun);
  }

  /// Sinyal valuasi. [nilaiDcf] (opsional) dari [dcf] ikut dirata-ratakan.
  Sinyal sinyal(DataFundamental d, {double? nilaiDcf}) {
    if (d.labaPerSaham <= 0) {
      return Sinyal.dariSkor(
        nama,
        -0.3,
        catatan: 'Laba negatif: valuasi berbasis laba tidak berlaku.',
      );
    }

    final estimasi = <double>[];
    final ag = angkaGraham(d.labaPerSaham, d.nilaiBukuPerSaham);
    if (ag != null) estimasi.add(ag);
    final ng = nilaiGraham(d.labaPerSaham, d.pertumbuhanLabaPersen);
    if (ng != null) estimasi.add(ng);
    if (nilaiDcf != null && nilaiDcf > 0) estimasi.add(nilaiDcf);

    final nilaiWajar = MathUtils.rata(estimasi);
    final margin = (nilaiWajar - d.harga) / nilaiWajar;
    final skorNilai = MathUtils.tanh(margin * 2);

    var skorKualitas = 0.0;
    if (d.roePersen != null) {
      skorKualitas += 0.5 * MathUtils.tanh((d.roePersen! - 10) / 10);
    }
    if (d.utangPerEkuitas != null) {
      skorKualitas -= 0.5 * MathUtils.tanh((d.utangPerEkuitas! - 1) / 1.5);
    }

    final skor = 0.7 * skorNilai + 0.3 * skorKualitas;
    final per = d.per, pbv = d.pbv;
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'PER ${per?.toStringAsFixed(1) ?? "-"}, PBV ${pbv?.toStringAsFixed(2) ?? "-"}, '
          'nilai wajar ${nilaiWajar.toStringAsFixed(0)} (margin ${(margin * 100).toStringAsFixed(0)}%)',
    );
  }
}
