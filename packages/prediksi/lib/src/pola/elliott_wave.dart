import 'dart:math' as math;

import '../core/models.dart';
import 'zigzag.dart';

/// Hasil deteksi pola impuls Elliott.
class PolaElliott {
  /// true = struktur impuls naik, false = impuls turun.
  final bool naik;

  /// Jumlah pivot yang cocok: 3 (gelombang 1-2), 5 (1-4), atau 6 (1-5 selesai).
  final int jumlahPivot;
  final String fase;
  final double skor;
  final List<Pivot> pivot;

  const PolaElliott({
    required this.naik,
    required this.jumlahPivot,
    required this.fase,
    required this.skor,
    required this.pivot,
  });
}

/// Deteksi Elliott Wave berbasis aturan (heuristik, bukan analisis subjektif).
///
/// Pivot dicari dengan [zigzag] berambang [ambang]. Pola impuls dianggap valid
/// bila memenuhi aturan baku: gelombang 2 tidak melewati awal gelombang 1,
/// gelombang 4 tidak tumpang tindih wilayah gelombang 1, dan gelombang 3
/// bukan yang terpendek di antara 1, 3, dan 5. Penghitungan gelombang aslinya
/// sangat subjektif; anggap hasil ini sebagai salah satu kemungkinan saja.
class ElliottWave implements MetodePrediksi {
  final double ambang;

  const ElliottWave({this.ambang = 0.05});

  @override
  String get nama => 'Elliott Wave';

  /// [p] = harga pivot dalam bentuk struktur naik (p[0] adalah lembah awal).
  static bool _impuls(List<double> p) {
    final w1 = p[1] - p[0];
    if (w1 <= 0) return false;
    if (p[2] <= p[0]) return false; // gelombang 2 tidak boleh melewati awal
    final retrace = (p[1] - p[2]) / w1;
    if (retrace < 0.3 || retrace > 0.9) return false;
    if (p.length == 3) return true;

    final w3 = p[3] - p[2];
    if (w3 <= 0 || p[3] <= p[1]) return false;
    if (p[4] <= p[1] || p[4] >= p[3]) return false; // tanpa tumpang tindih
    if (p.length == 5) return w3 >= w1;

    final w5 = p[5] - p[4];
    if (w5 <= 0) return false;
    return w3 >= math.min(w1, w5); // gelombang 3 bukan yang terpendek
  }

  /// Cari pola impuls pada ujung deret harga; null bila tidak ada.
  PolaElliott? deteksi(List<Candle> data) {
    final pivot = zigzag(data.map((c) => c.close).toList(), ambang: ambang);

    for (final n in const [6, 5, 3]) {
      if (pivot.length < n) continue;
      final jendela = pivot.sublist(pivot.length - n);
      final naik = !jendela.first.tinggi; // mulai dari lembah = impuls naik
      final harga = [for (final p in jendela) naik ? p.harga : -p.harga];
      if (!_impuls(harga)) continue;

      final s = naik ? 1.0 : -1.0;
      return switch (n) {
        3 => PolaElliott(
            naik: naik,
            jumlahPivot: n,
            fase: 'Gelombang 2 selesai, gelombang 3 diperkirakan',
            skor: s * 0.6,
            pivot: jendela,
          ),
        5 => PolaElliott(
            naik: naik,
            jumlahPivot: n,
            fase: 'Gelombang 4 selesai, gelombang 5 diperkirakan',
            skor: s * 0.35,
            pivot: jendela,
          ),
        _ => PolaElliott(
            naik: naik,
            jumlahPivot: n,
            fase: 'Gelombang 5 selesai, koreksi A-B-C diperkirakan',
            skor: -s * 0.5,
            pivot: jendela,
          ),
      };
    }
    return null;
  }

  @override
  Sinyal analisis(List<Candle> data) {
    final pola = deteksi(data);
    if (pola == null) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Tidak ada pola impuls terdeteksi.',
      );
    }
    return Sinyal.dariSkor(
      nama,
      pola.skor,
      catatan:
          '${pola.naik ? "Impuls naik" : "Impuls turun"}: ${pola.fase}',
    );
  }
}
