import '../core/models.dart';
import 'siklus_dasar.dart';

/// Tiga jenis tahun menurut Benner.
enum JenisTahun {
  /// Tahun A: kepanikan / krisis pasar.
  panic,

  /// Tahun B: harga tinggi, waktu menjual.
  goodTimes,

  /// Tahun C: harga rendah, waktu membeli dan menahan.
  hardTimes,
}

/// Benner Cycle.
///
/// Tabel bawaan adalah versi yang umum beredar (bukan murni karya Benner
/// 1875, sudah diperluas pihak lain) dan belum diverifikasi ke sumber asli.
/// Ganti lewat parameter [tabel] bila kamu punya versi sendiri.
class SiklusBenner implements MetodeSiklus {
  final Map<JenisTahun, List<int>> tabel;

  SiklusBenner({Map<JenisTahun, List<int>>? tabel})
      : tabel = tabel ?? tabelBawaan;

  static const Map<JenisTahun, List<int>> tabelBawaan = {
    JenisTahun.panic: [1927, 1945, 1965, 1981, 1999, 2019, 2035, 2053],
    JenisTahun.goodTimes: [
      1926, 1935, 1945, 1953, 1962, 1972, 1980, 1989, //
      1999, 2007, 2016, 2026, 2034, 2043, 2053, 2062,
    ],
    JenisTahun.hardTimes: [
      1931, 1942, 1958, 1967, 1977, 1985, 1996, //
      2012, 2023, 2032, 2039, 2050, 2059,
    ],
  };

  @override
  String get nama => 'Benner Cycle';

  static const _skorTahun = {
    JenisTahun.panic: -1.0,
    JenisTahun.goodTimes: -0.6,
    JenisTahun.hardTimes: 0.6,
  };

  static const _label = {
    JenisTahun.panic: 'Panic (A)',
    JenisTahun.goodTimes: 'Good times (B), saat menjual',
    JenisTahun.hardTimes: 'Hard times (C), saat membeli',
  };

  /// Semua jenis yang jatuh pada [tahun] (satu tahun bisa punya lebih dari satu).
  List<JenisTahun> jenisPada(int tahun) => [
        for (final e in tabel.entries)
          if (e.value.contains(tahun)) e.key,
      ];

  List<(int, JenisTahun)> _peristiwa() {
    final out = <(int, JenisTahun)>[];
    tabel.forEach((j, daftar) {
      for (final y in daftar) {
        out.add((y, j));
      }
    });
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// Peristiwa terakhir sebelum (atau pada) [tahun] dan berikutnya setelahnya.
  ({(int, JenisTahun)? terakhir, (int, JenisTahun)? berikut}) sekitar(int tahun) {
    (int, JenisTahun)? terakhir, berikut;
    for (final p in _peristiwa()) {
      if (p.$1 <= tahun) {
        terakhir = p;
      } else {
        berikut ??= p;
      }
    }
    return (terakhir: terakhir, berikut: berikut);
  }

  @override
  Sinyal pada(DateTime tanggal) {
    final tahun = tanggal.year;
    final jenis = jenisPada(tahun);

    if (jenis.isNotEmpty) {
      // Jika bertumpuk, pakai yang paling hati-hati (skor terendah).
      jenis.sort((a, b) => _skorTahun[a]!.compareTo(_skorTahun[b]!));
      final j = jenis.first;
      final semua = jenis.map((e) => _label[e]).join(' + ');
      return Sinyal.dariSkor(nama, _skorTahun[j]!,
          catatan: 'Tahun $tahun: $semua');
    }

    final s = sekitar(tahun);
    if (s.terakhir == null) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Tahun $tahun di luar cakupan tabel.',
      );
    }
    final jenisTerakhir = s.terakhir!.$2;
    final skor = switch (jenisTerakhir) {
      JenisTahun.hardTimes => 0.3, // pemulihan menuju good times
      JenisTahun.goodTimes => -0.3, // turun menuju hard times
      JenisTahun.panic => 0.0,
    };
    final berikut = s.berikut == null
        ? ''
        : ', berikutnya ${s.berikut!.$1} (${_label[s.berikut!.$2]})';
    return Sinyal.dariSkor(nama, skor,
        catatan:
            'Fase antar tahun, terakhir ${s.terakhir!.$1} (${_label[jenisTerakhir]})$berikut');
  }
}
