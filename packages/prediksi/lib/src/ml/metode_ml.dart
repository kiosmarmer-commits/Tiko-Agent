import '../core/models.dart';
import 'dasar_ml.dart';
import 'fitur_pasar.dart';
import 'hutan_acak.dart';
import 'knn.dart';
import 'pohon_keputusan.dart';

/// Membungkus pengklasifikasi biner menjadi [MetodePrediksi].
///
/// Setiap kali [analisis] dipanggil, model dilatih ulang pada data historis
/// (hanya label yang sudah diketahui) lalu memprediksi titik terakhir.
/// Skor = (P(naik) - 0.5) * 2.
class MetodeML implements MetodePrediksi {
  final String _nama;
  final PengklasifikasiBiner Function() _pembuat;

  /// Berapa periode ke depan yang diprediksi.
  final int horizon;

  /// Batas jumlah sampel latih terbaru (menjaga kecepatan).
  final int maksLatih;

  /// Sampel latih minimum agar model dianggap layak.
  final int minLatih;

  MetodeML({
    required String nama,
    required PengklasifikasiBiner Function() pembuat,
    this.horizon = 5,
    this.maksLatih = 1000,
    this.minLatih = 60,
  })  : _nama = nama,
        _pembuat = pembuat;

  factory MetodeML.knn({int k = 15, int horizon = 5}) => MetodeML(
        nama: 'KNN(k=$k)',
        pembuat: () => KNN(k: k),
        horizon: horizon,
      );

  factory MetodeML.pohon({int maksKedalaman = 4, int horizon = 5}) => MetodeML(
        nama: 'Pohon Keputusan',
        pembuat: () => PohonKeputusan(maksKedalaman: maksKedalaman),
        horizon: horizon,
      );

  factory MetodeML.hutan({int jumlahPohon = 50, int horizon = 5}) => MetodeML(
        nama: 'Random Forest',
        pembuat: () => HutanAcak(jumlahPohon: jumlahPohon),
        horizon: horizon,
      );

  @override
  String get nama => _nama;

  @override
  Sinyal analisis(List<Candle> data) {
    final fitur = FiturPasar(data);
    final latihan = fitur.dataLatih(horizon: horizon);
    final vektorTerakhir = fitur.vektor(data.length - 1);

    if (vektorTerakhir == null || latihan.x.length < minLatih) {
      return Sinyal(
        metode: nama,
        arah: Arah.tahan,
        skor: 0,
        catatan:
            'Data kurang (sampel latih ${latihan.x.length}, butuh >= $minLatih).',
      );
    }

    var x = latihan.x, y = latihan.y;
    if (x.length > maksLatih) {
      x = x.sublist(x.length - maksLatih);
      y = y.sublist(y.length - maksLatih);
    }

    final model = _pembuat()..latih(x, y);
    final p = model.peluang(vektorTerakhir);
    return Sinyal.dariSkor(
      nama,
      (p - 0.5) * 2,
      catatan:
          'P(naik $horizon periode) ${(p * 100).toStringAsFixed(0)}%, dilatih pada ${x.length} sampel',
    );
  }
}
