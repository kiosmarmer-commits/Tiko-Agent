import '../core/models.dart';
import 'fitur_pasar.dart';
import 'lstm_biner.dart';

/// Memprediksi arah harga [horizon] periode ke depan dengan LSTM yang dilatih
/// pada urutan fitur pasar sepanjang [panjangUrutan] langkah.
///
/// Model dilatih ulang tiap kali [analisis] dipanggil, hanya dengan label yang
/// sudah diketahui (tanpa kebocoran masa depan). Skor = (P(naik) - 0.5) * 2.
/// Pelatihan di Dart murni cukup lambat; kecilkan [maksLatih] atau [epoch]
/// bila perlu.
class MetodeLSTM implements MetodePrediksi {
  final int horizon;
  final int panjangUrutan;
  final int tersembunyi;
  final int epoch;
  final int maksLatih;
  final int minLatih;

  const MetodeLSTM({
    this.horizon = 5,
    this.panjangUrutan = 10,
    this.tersembunyi = 8,
    this.epoch = 25,
    this.maksLatih = 400,
    this.minLatih = 80,
  });

  @override
  String get nama => 'LSTM';

  /// Urutan fitur berakhir di indeks [i], diratakan; null jika ada yang kosong.
  List<double>? _urutan(FiturPasar fitur, int i) {
    final out = <double>[];
    for (var t = i - panjangUrutan + 1; t <= i; t++) {
      final v = fitur.vektor(t);
      if (v == null) return null;
      out.addAll(v);
    }
    return out;
  }

  @override
  Sinyal analisis(List<Candle> data) {
    final n = data.length;
    final fitur = FiturPasar(data);

    var x = <List<double>>[];
    var y = <int>[];
    final awal = FiturPasar.minIndeks + panjangUrutan - 1;
    for (var i = awal; i < n - horizon; i++) {
      final u = _urutan(fitur, i);
      if (u == null) continue;
      x.add(u);
      y.add(data[i + horizon].close > data[i].close ? 1 : 0);
    }
    final terakhir = n > 0 ? _urutan(fitur, n - 1) : null;

    if (terakhir == null || x.length < minLatih) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan: 'Data kurang (sampel latih ${x.length}, butuh >= $minLatih).',
      );
    }
    if (x.length > maksLatih) {
      x = x.sublist(x.length - maksLatih);
      y = y.sublist(y.length - maksLatih);
    }

    final model = LstmBiner(
      panjangUrutan: panjangUrutan,
      tersembunyi: tersembunyi,
      epoch: epoch,
    )..latih(x, y);
    final p = model.peluang(terakhir);
    return Sinyal.dariSkor(
      nama,
      (p - 0.5) * 2,
      catatan:
          'P(naik $horizon periode) ${(p * 100).toStringAsFixed(0)}%, dilatih pada ${x.length} urutan',
    );
  }
}
