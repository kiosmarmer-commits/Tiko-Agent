import '../core/models.dart';

/// Hasil penggabungan: sinyal akhir, tingkat kesepakatan, dan rincian.
class HasilEnsemble {
  final Sinyal sinyal;

  /// Proporsi bobot yang arahnya sama dengan arah akhir (0..1).
  /// Makin rendah, makin terpecah pendapat antar metode.
  final double kesepakatan;

  /// Sinyal tiap metode yang ikut digabung.
  final List<Sinyal> rincian;

  const HasilEnsemble({
    required this.sinyal,
    required this.kesepakatan,
    required this.rincian,
  });

  @override
  String toString() =>
      'HasilEnsemble(${sinyal.arah.name}, skor ${sinyal.skor.toStringAsFixed(2)}, '
      'kesepakatan ${(kesepakatan * 100).toStringAsFixed(0)}%)';
}

/// Menggabungkan banyak metode menjadi satu sinyal lewat rata-rata berbobot.
///
/// Metode berbasis candle dimasukkan lewat [metode]. Sinyal dari metode lain
/// (siklus, makro, fundamental, Delphi, dst.) dimasukkan lewat parameter
/// `tambahan` pada [hitung]. Menggabungkan metode yang berbeda sifatnya
/// biasanya lebih stabil daripada mengandalkan satu metode.
class Ensemble implements MetodePrediksi {
  final List<MetodePrediksi> metode;

  /// Bobot per metode (urutan sama dengan [metode]); default semua 1.
  final List<double>? bobot;

  /// Skor di atas +ambang = beli, di bawah -ambang = jual.
  final double ambang;

  final String _nama;

  Ensemble(
    this.metode, {
    this.bobot,
    this.ambang = 0.2,
    String nama = 'Ensemble',
  })  : _nama = nama,
        assert(bobot == null || bobot.length == metode.length);

  @override
  String get nama => _nama;

  /// Gabungkan daftar [sinyal] menjadi satu hasil.
  static HasilEnsemble gabungkanSinyal(
    List<Sinyal> sinyal, {
    List<double>? bobot,
    double ambang = 0.2,
    String nama = 'Ensemble',
  }) {
    if (sinyal.isEmpty) {
      return HasilEnsemble(
        sinyal: Sinyal(
          metode: nama,
          arah: Arah.tahan,
          skor: 0,
          catatan: 'Tidak ada sinyal untuk digabung.',
        ),
        kesepakatan: 0,
        rincian: const [],
      );
    }
    if (bobot != null && bobot.length != sinyal.length) {
      throw ArgumentError('Jumlah bobot harus sama dengan jumlah sinyal');
    }

    var jumlah = 0.0, total = 0.0;
    for (var i = 0; i < sinyal.length; i++) {
      final w = bobot?[i] ?? 1.0;
      jumlah += sinyal[i].skor * w;
      total += w;
    }
    final akhir = Sinyal.dariSkor(
      nama,
      jumlah / total,
      ambang: ambang,
      catatan: sinyal
          .map((s) => '${s.metode}: ${s.skor.toStringAsFixed(2)}')
          .join(' | '),
    );

    var searah = 0.0;
    for (var i = 0; i < sinyal.length; i++) {
      if (sinyal[i].arah == akhir.arah) searah += bobot?[i] ?? 1.0;
    }
    return HasilEnsemble(
      sinyal: akhir,
      kesepakatan: searah / total,
      rincian: List<Sinyal>.unmodifiable(sinyal),
    );
  }

  /// Jalankan semua [metode] pada [data], tambahkan [tambahan] (mis. sinyal
  /// siklus/makro), lalu gabungkan. [bobotTambahan] sepanjang [tambahan].
  HasilEnsemble hitung(
    List<Candle> data, {
    List<Sinyal> tambahan = const [],
    List<double>? bobotTambahan,
  }) {
    if (bobotTambahan != null && bobotTambahan.length != tambahan.length) {
      throw ArgumentError('bobotTambahan harus sepanjang tambahan');
    }
    final semua = <Sinyal>[for (final m in metode) m.analisis(data), ...tambahan];
    final bobotSemua = <double>[
      ...(bobot ?? List<double>.filled(metode.length, 1.0)),
      ...(bobotTambahan ?? List<double>.filled(tambahan.length, 1.0)),
    ];
    return gabungkanSinyal(
      semua,
      bobot: bobotSemua,
      ambang: ambang,
      nama: nama,
    );
  }

  @override
  Sinyal analisis(List<Candle> data) => hitung(data).sinyal;
}
