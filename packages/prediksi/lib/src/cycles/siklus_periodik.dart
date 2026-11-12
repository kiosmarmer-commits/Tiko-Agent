import 'dart:math' as math;

import '../core/models.dart';
import 'siklus_dasar.dart';

/// Siklus periodik generik: gelombang dengan periode tetap.
///
/// Fase 0.0 = puncak (cenderung menjual), 0.5 = lembah (cenderung membeli).
/// Skor = -cos(2*pi*fase), jadi +1 di lembah dan -1 di puncak.
///
/// PERHATIAN: tahun acuan pada preset hanyalah perkiraan kasar untuk
/// demonstrasi. Siklus ekonomi nyata tidak teratur. Sesuaikan [acuanPuncak]
/// dengan data/riset kamu sendiri.
class SiklusPeriodik implements MetodeSiklus {
  @override
  final String nama;

  /// Panjang satu siklus penuh, dalam tahun.
  final double periodeTahun;

  /// Tahun (desimal) yang dianggap puncak siklus.
  final double acuanPuncak;

  const SiklusPeriodik({
    required this.nama,
    required this.periodeTahun,
    required this.acuanPuncak,
  });

  /// Kondratiev: ~50 tahun.
  const SiklusPeriodik.kondratiev({double acuanPuncak = 1974})
      : this(nama: 'Kondratiev', periodeTahun: 50, acuanPuncak: acuanPuncak);

  /// Kitchin: ~4 tahun (siklus persediaan).
  const SiklusPeriodik.kitchin({double acuanPuncak = 2022})
      : this(nama: 'Kitchin', periodeTahun: 4, acuanPuncak: acuanPuncak);

  /// Juglar: ~9 tahun (siklus investasi).
  const SiklusPeriodik.juglar({double acuanPuncak = 2018})
      : this(nama: 'Juglar', periodeTahun: 9, acuanPuncak: acuanPuncak);

  /// Kuznets: ~20 tahun (infrastruktur/demografi).
  const SiklusPeriodik.kuznets({double acuanPuncak = 2007})
      : this(nama: 'Kuznets', periodeTahun: 20, acuanPuncak: acuanPuncak);

  /// Siklus properti ~18 tahun (Homer Hoyt).
  const SiklusPeriodik.properti18({double acuanPuncak = 2007})
      : this(nama: 'Properti 18 tahun', periodeTahun: 18, acuanPuncak: acuanPuncak);

  /// Fase 0..1 pada [tanggal].
  double fase(DateTime tanggal) {
    final x = (tahunDesimal(tanggal) - acuanPuncak) / periodeTahun;
    return x - x.floorToDouble();
  }

  @override
  Sinyal pada(DateTime tanggal) {
    final f = fase(tanggal);
    final skor = -math.cos(2 * math.pi * f);
    final posisi = f < 0.25
        ? 'turun dari puncak'
        : f < 0.5
            ? 'menuju lembah'
            : f < 0.75
                ? 'naik dari lembah'
                : 'menuju puncak';
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan: 'Fase ${(f * 100).toStringAsFixed(0)}% ($posisi)',
    );
  }
}
