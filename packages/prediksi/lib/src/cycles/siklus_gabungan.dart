import '../core/models.dart';
import 'benner.dart';
import 'halving_bitcoin.dart';
import 'siklus_dasar.dart';
import 'siklus_periodik.dart';

/// Rata-rata berbobot dari beberapa metode siklus.
class SiklusGabungan implements MetodeSiklus {
  final List<MetodeSiklus> metode;

  /// Bobot per metode (urutan sama dengan [metode]); default semua 1.
  final List<double>? bobot;

  SiklusGabungan(this.metode, {this.bobot})
      : assert(metode.isNotEmpty),
        assert(bobot == null || bobot.length == metode.length);

  /// Paket bawaan untuk pasar umum (tanpa halving Bitcoin).
  factory SiklusGabungan.pasarUmum() => SiklusGabungan([
        SiklusBenner(),
        const SiklusPeriodik.kondratiev(),
        const SiklusPeriodik.kuznets(),
        const SiklusPeriodik.juglar(),
        const SiklusPeriodik.kitchin(),
      ]);

  /// Paket untuk kripto: siklus umum ditambah halving Bitcoin.
  factory SiklusGabungan.kripto() => SiklusGabungan([
        HalvingBitcoin(),
        const SiklusPeriodik.kitchin(),
        SiklusBenner(),
      ], bobot: [2, 1, 1]);

  @override
  String get nama => 'Siklus Gabungan';

  @override
  Sinyal pada(DateTime tanggal) {
    var jumlah = 0.0, totalBobot = 0.0;
    final rincian = <String>[];
    for (var i = 0; i < metode.length; i++) {
      final w = bobot?[i] ?? 1.0;
      final s = metode[i].pada(tanggal);
      jumlah += s.skor * w;
      totalBobot += w;
      rincian.add('${s.metode}: ${s.skor.toStringAsFixed(2)}');
    }
    return Sinyal.dariSkor(
      nama,
      jumlah / totalBobot,
      catatan: rincian.join(' | '),
    );
  }
}
