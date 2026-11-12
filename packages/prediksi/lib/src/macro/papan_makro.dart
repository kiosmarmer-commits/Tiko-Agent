import '../core/models.dart';
import 'indikator_makro.dart';
import 'sentimen.dart';
import 'yield_curve.dart';

/// Snapshot data makro dan sentimen yang kamu isi sendiri. Semua field
/// opsional; indikator yang datanya tidak diisi akan dilewati.
class DataMakro {
  // Yield curve (persen)
  final double? hasilPanjang;
  final double? hasilPendek;
  final double? spreadSebelumnya;

  // Suku bunga dan inflasi (persen)
  final double? sukuBunga;
  final double? sukuBungaSebelumnya;
  final double? inflasi;

  // PMI manufaktur
  final double? pmi;
  final double? pmiSebelumnya;

  // Pengangguran bulanan (urut dari terlama), untuk aturan Sahm
  final List<double>? pengangguran;

  // Sentimen
  final double? vix;
  final double? indeksTakutSerakah;

  const DataMakro({
    this.hasilPanjang,
    this.hasilPendek,
    this.spreadSebelumnya,
    this.sukuBunga,
    this.sukuBungaSebelumnya,
    this.inflasi,
    this.pmi,
    this.pmiSebelumnya,
    this.pengangguran,
    this.vix,
    this.indeksTakutSerakah,
  });
}

/// Menjalankan semua indikator makro/sentimen yang datanya tersedia.
class PapanMakro {
  final YieldCurve yieldCurve;
  final SukuBungaInflasi sukuBungaInflasi;
  final PmiManufaktur pmi;
  final AturanSahm sahm;
  final IndeksVix vix;
  final FearGreed fearGreed;

  const PapanMakro({
    this.yieldCurve = const YieldCurve(),
    this.sukuBungaInflasi = const SukuBungaInflasi(),
    this.pmi = const PmiManufaktur(),
    this.sahm = const AturanSahm(),
    this.vix = const IndeksVix(),
    this.fearGreed = const FearGreed(),
  });

  /// Sinyal tiap indikator yang datanya lengkap.
  List<Sinyal> semua(DataMakro d) {
    final hasil = <Sinyal>[];

    final hp = d.hasilPanjang, hd = d.hasilPendek;
    if (hp != null && hd != null) {
      hasil.add(yieldCurve.sinyal(
        hasilPanjang: hp,
        hasilPendek: hd,
        spreadSebelumnya: d.spreadSebelumnya,
      ));
    }

    final sb = d.sukuBunga, sbs = d.sukuBungaSebelumnya, inf = d.inflasi;
    if (sb != null && sbs != null && inf != null) {
      hasil.add(sukuBungaInflasi.sinyal(
        sukuBunga: sb,
        sukuBungaSebelumnya: sbs,
        inflasi: inf,
      ));
    }

    final p = d.pmi;
    if (p != null) {
      hasil.add(pmi.sinyal(pmi: p, pmiSebelumnya: d.pmiSebelumnya));
    }

    final peng = d.pengangguran;
    if (peng != null) hasil.add(sahm.sinyal(peng));

    final v = d.vix;
    if (v != null) hasil.add(vix.sinyal(v));

    final fg = d.indeksTakutSerakah;
    if (fg != null) hasil.add(fearGreed.sinyal(fg));

    return hasil;
  }

  /// Rata-rata skor semua indikator yang tersedia.
  Sinyal gabungan(DataMakro d) {
    final daftar = semua(d);
    if (daftar.isEmpty) {
      return const Sinyal(
        metode: 'Papan Makro',
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Tidak ada data makro yang diisi.',
      );
    }
    final skor =
        daftar.map((s) => s.skor).reduce((a, b) => a + b) / daftar.length;
    return Sinyal.dariSkor(
      'Papan Makro',
      skor,
      catatan: daftar
          .map((s) => '${s.metode}: ${s.skor.toStringAsFixed(2)}')
          .join(' | '),
    );
  }
}
