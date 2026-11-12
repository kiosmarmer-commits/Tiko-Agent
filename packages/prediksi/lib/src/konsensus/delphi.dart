import '../core/math_utils.dart';
import '../core/models.dart';

/// Ringkasan statistik satu putaran estimasi pakar.
class RingkasanDelphi {
  final double median;
  final double q1;
  final double q3;

  /// Rentang antar-kuartil (q3 - q1).
  final double iqr;

  /// Dispersi relatif: iqr / |median|. Makin kecil makin sepakat.
  final double dispersi;

  /// true bila dispersi <= ambang konsensus.
  final bool konsensus;

  const RingkasanDelphi({
    required this.median,
    required this.q1,
    required this.q3,
    required this.iqr,
    required this.dispersi,
    required this.konsensus,
  });
}

/// Metode Delphi: beberapa pakar memberi estimasi numerik (mis. harga target),
/// hasil dirangkum lalu dibagikan kembali, pakar merevisi, dan diulang sampai
/// pendapat mengerucut. Kelas ini mengagregasi estimasi dan dapat mensimulasikan
/// konvergensi; pengumpulan estimasi dari pakar dilakukan di luar paket.
class Delphi {
  /// Dispersi relatif maksimum agar dianggap konsensus.
  final double ambangKonsensus;

  const Delphi({this.ambangKonsensus = 0.15});

  String get nama => 'Delphi';

  /// Median (berbobot bila [bobot] diberikan, mis. bobot keahlian pakar).
  static double median(List<double> estimasi, {List<double>? bobot}) {
    if (bobot == null) return MathUtils.persentil(estimasi, 50);
    if (bobot.length != estimasi.length) {
      throw ArgumentError('Jumlah bobot harus sama dengan jumlah estimasi');
    }
    final pasangan = [
      for (var i = 0; i < estimasi.length; i++) (estimasi[i], bobot[i]),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final total = pasangan.fold<double>(0, (s, p) => s + p.$2);
    var kumulatif = 0.0;
    for (final p in pasangan) {
      kumulatif += p.$2;
      if (kumulatif >= total / 2) return p.$1;
    }
    return pasangan.last.$1;
  }

  RingkasanDelphi ringkas(List<double> estimasi, {List<double>? bobot}) {
    if (estimasi.isEmpty) throw ArgumentError('Estimasi kosong');
    final med = median(estimasi, bobot: bobot);
    final q1 = MathUtils.persentil(estimasi, 25);
    final q3 = MathUtils.persentil(estimasi, 75);
    final iqr = q3 - q1;
    final dispersi = med == 0 ? double.infinity : iqr / med.abs();
    return RingkasanDelphi(
      median: med,
      q1: q1,
      q3: q3,
      iqr: iqr,
      dispersi: dispersi,
      konsensus: dispersi <= ambangKonsensus,
    );
  }

  /// Putaran berikut: tiap pakar bergeser ke arah median sebesar [tarikan]
  /// (0 = tidak berubah, 1 = sama persis dengan median).
  List<double> putaranBerikut(List<double> estimasi, {double tarikan = 0.3}) {
    final med = median(estimasi);
    return [for (final e in estimasi) e + (med - e) * tarikan];
  }

  /// Simulasikan [putaran] putaran dan kembalikan ringkasan tiap putaran
  /// (indeks 0 = putaran awal).
  List<RingkasanDelphi> simulasi(
    List<double> awal, {
    int putaran = 3,
    double tarikan = 0.3,
  }) {
    final hasil = <RingkasanDelphi>[ringkas(awal)];
    var saat = awal;
    for (var i = 0; i < putaran; i++) {
      saat = putaranBerikut(saat, tarikan: tarikan);
      hasil.add(ringkas(saat));
    }
    return hasil;
  }

  /// Sinyal dari median estimasi (harga target) dibanding [hargaSaatIni].
  /// Makin besar perbedaan pendapat antar pakar, makin kecil keyakinan.
  Sinyal sinyal(
    List<double> estimasi, {
    required double hargaSaatIni,
    List<double>? bobot,
  }) {
    if (estimasi.length < 3) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Butuh minimal 3 estimasi pakar.',
      );
    }
    final r = ringkas(estimasi, bobot: bobot);
    final ret = r.median / hargaSaatIni - 1;
    final keyakinan =
        r.dispersi.isInfinite ? 0.0 : (1 - r.dispersi / 0.5).clamp(0.0, 1.0);
    final skor = MathUtils.tanh(ret * 5) * keyakinan;
    return Sinyal.dariSkor(
      nama,
      skor,
      catatan:
          'Median target ${r.median.toStringAsFixed(2)} (${(ret * 100).toStringAsFixed(1)}% dari harga), '
          'dispersi ${r.dispersi.toStringAsFixed(2)}, ${r.konsensus ? "konsensus" : "belum konsensus"}',
    );
  }
}
