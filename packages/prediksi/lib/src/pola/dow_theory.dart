import '../core/models.dart';
import 'zigzag.dart';

enum TrenDow { naik, turun, menyamping }

/// Dow Theory versi terukur.
///
/// Tren naik = puncak dan lembah terakhir sama-sama lebih tinggi dari
/// sebelumnya (higher high + higher low); tren turun = keduanya lebih rendah;
/// selain itu dianggap menyamping. Pivot dicari dengan [zigzag] berambang
/// [ambang]. Volume (jika ada) dipakai sebagai konfirmasi: tren sehat bila
/// volume lebih besar pada gerakan searah tren.
class DowTheory implements MetodePrediksi {
  final double ambang;

  const DowTheory({this.ambang = 0.03});

  @override
  String get nama => 'Dow Theory';

  TrenDow tren(List<Candle> data) {
    final pivot = zigzag(data.map((c) => c.close).toList(), ambang: ambang);
    final tinggi = pivot.where((p) => p.tinggi).toList();
    final rendah = pivot.where((p) => !p.tinggi).toList();
    if (tinggi.length < 2 || rendah.length < 2) return TrenDow.menyamping;

    final hh = tinggi.last.harga > tinggi[tinggi.length - 2].harga;
    final hl = rendah.last.harga > rendah[rendah.length - 2].harga;
    if (hh && hl) return TrenDow.naik;
    if (!hh && !hl) return TrenDow.turun;
    return TrenDow.menyamping;
  }

  /// Rasio rata-rata volume candle naik terhadap candle turun pada
  /// [jendela] candle terakhir; null bila tidak ada data volume.
  double? rasioVolume(List<Candle> data, {int jendela = 50}) {
    final mulai = data.length > jendela ? data.length - jendela : 1;
    var volNaik = 0.0, volTurun = 0.0;
    var nNaik = 0, nTurun = 0;
    for (var i = mulai < 1 ? 1 : mulai; i < data.length; i++) {
      if (data[i].close > data[i - 1].close) {
        volNaik += data[i].volume;
        nNaik++;
      } else if (data[i].close < data[i - 1].close) {
        volTurun += data[i].volume;
        nTurun++;
      }
    }
    if (nNaik == 0 || nTurun == 0 || volNaik + volTurun == 0 || volTurun == 0) {
      return null;
    }
    return (volNaik / nNaik) / (volTurun / nTurun);
  }

  @override
  Sinyal analisis(List<Candle> data) {
    final t = tren(data);
    final rv = rasioVolume(data);
    var skor = switch (t) {
      TrenDow.naik => 0.7,
      TrenDow.turun => -0.7,
      TrenDow.menyamping => 0.0,
    };
    var ket = 'Tren ${t.name}';

    if (rv != null && t != TrenDow.menyamping) {
      // Volume harus mengonfirmasi arah tren.
      final terkonfirmasi = (t == TrenDow.naik && rv > 1) ||
          (t == TrenDow.turun && rv < 1);
      skor += (t == TrenDow.naik ? 1 : -1) * (terkonfirmasi ? 0.1 : -0.2);
      ket += terkonfirmasi
          ? ', volume mengonfirmasi'
          : ', volume tidak mengonfirmasi (waspada)';
    }
    return Sinyal.dariSkor(nama, skor, catatan: ket);
  }

  /// Konfirmasi dua indeks/aset (versi Dow: Industrials + Transports).
  /// Sinyal kuat hanya jika keduanya searah.
  Sinyal konfirmasi(List<Candle> a, List<Candle> b) {
    final ta = tren(a), tb = tren(b);
    if (ta == tb && ta != TrenDow.menyamping) {
      final skor = ta == TrenDow.naik ? 0.9 : -0.9;
      return Sinyal.dariSkor(nama, skor,
          catatan: 'Kedua indeks tren ${ta.name} (terkonfirmasi)');
    }
    return Sinyal(
      metode: nama,
      arah: Arah.tahan,
      skor: 0,
      catatan: 'Tidak terkonfirmasi (A: ${ta.name}, B: ${tb.name})',
    );
  }
}
