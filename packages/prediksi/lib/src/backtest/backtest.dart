import '../core/models.dart';
import '../risiko/manajemen_risiko.dart';

/// Satu transaksi hasil backtest.
class Transaksi {
  final int indeksMasuk;
  final int indeksKeluar;
  final double hargaMasuk;
  final double hargaKeluar;
  final bool posisiLong;

  const Transaksi({
    required this.indeksMasuk,
    required this.indeksKeluar,
    required this.hargaMasuk,
    required this.hargaKeluar,
    required this.posisiLong,
  });

  /// Return transaksi sebelum biaya.
  double get imbal => posisiLong
      ? hargaKeluar / hargaMasuk - 1
      : hargaMasuk / hargaKeluar - 1;
}

/// Hasil backtest beserta metrik utama.
class HasilBacktest {
  /// Kurva ekuitas; elemen pertama = modal awal.
  final List<double> ekuitas;

  /// Return strategi per periode (setelah biaya).
  final List<double> returnPeriode;
  final List<Transaksi> transaksi;

  /// Return beli-dan-tahan pada rentang yang sama, sebagai pembanding.
  final double returnBeliTahan;

  /// Jumlah perubahan posisi (masuk, keluar, atau balik arah).
  final int jumlahPerubahanPosisi;

  const HasilBacktest({
    required this.ekuitas,
    required this.returnPeriode,
    required this.transaksi,
    required this.returnBeliTahan,
    required this.jumlahPerubahanPosisi,
  });

  double get totalReturn => ekuitas.last / ekuitas.first - 1;

  double get maxDrawdown => ManajemenRisiko.maxDrawdown(ekuitas);

  double sharpe({int periodePerTahun = 252}) => ManajemenRisiko.sharpe(
        returnPeriode,
        periodePerTahun: periodePerTahun,
      );

  /// Proporsi transaksi yang untung (sebelum biaya); 0 jika tidak ada transaksi.
  double get winRate => transaksi.isEmpty
      ? 0
      : transaksi.where((t) => t.imbal > 0).length / transaksi.length;

  @override
  String toString() =>
      'HasilBacktest(return ${(totalReturn * 100).toStringAsFixed(1)}%, '
      'beli-tahan ${(returnBeliTahan * 100).toStringAsFixed(1)}%, '
      'maxDD ${(maxDrawdown * 100).toStringAsFixed(1)}%, '
      'transaksi ${transaksi.length}, winRate ${(winRate * 100).toStringAsFixed(0)}%)';
}

/// Backtest walk-forward: pada tiap titik waktu, metode hanya melihat candle
/// sampai titik itu. Posisi dari sinyal di penutupan candle i berlaku untuk
/// return penutupan i ke i+1.
///
/// Batasan: eksekusi diasumsikan pada harga penutupan yang sama dengan saat
/// sinyal dihitung (sedikit optimistis), tanpa slippage selain [biayaPerTransaksi],
/// tanpa pajak, dan tanpa ukuran posisi (selalu 100% modal atau tunai).
/// Hasil backtest bagus tidak menjamin hasil nyata.
class Backtest {
  /// Jumlah candle minimum sebelum sinyal pertama dihitung.
  final int mulai;

  /// Hitung ulang sinyal tiap [interval] candle (besarkan untuk metode lambat
  /// seperti LSTM); posisi dipertahankan di antaranya.
  final int interval;

  /// Jika true, sinyal jual membuka posisi short; jika false, jual = tunai.
  final bool izinkanShort;

  /// Biaya per perubahan posisi sebagai proporsi (0.001 = 0,1%).
  final double biayaPerTransaksi;

  const Backtest({
    this.mulai = 100,
    this.interval = 1,
    this.izinkanShort = false,
    this.biayaPerTransaksi = 0.001,
  })  : assert(mulai >= 1),
        assert(interval >= 1);

  HasilBacktest jalankan(
    MetodePrediksi metode,
    List<Candle> data, {
    double modalAwal = 1.0,
  }) {
    final n = data.length;
    if (n <= mulai + 1) {
      throw ArgumentError(
          'Data (${data.length}) harus lebih banyak dari mulai + 1 (${mulai + 1})');
    }

    var posisi = 0; // 1 long, -1 short, 0 tunai
    var ekuitas = modalAwal;
    final kurva = <double>[ekuitas];
    final returns = <double>[];
    final transaksi = <Transaksi>[];
    var perubahan = 0;
    int? indeksMasuk;

    void tutup(int i) {
      if (posisi != 0 && indeksMasuk != null) {
        transaksi.add(Transaksi(
          indeksMasuk: indeksMasuk!,
          indeksKeluar: i,
          hargaMasuk: data[indeksMasuk!].close,
          hargaKeluar: data[i].close,
          posisiLong: posisi == 1,
        ));
      }
    }

    for (var i = mulai; i < n - 1; i++) {
      var biaya = 0.0;
      if ((i - mulai) % interval == 0) {
        final s = metode.analisis(data.sublist(0, i + 1));
        final target = s.arah == Arah.beli
            ? 1
            : (s.arah == Arah.jual && izinkanShort ? -1 : 0);
        if (target != posisi) {
          tutup(i);
          biaya = biayaPerTransaksi * (target - posisi).abs();
          posisi = target;
          indeksMasuk = target == 0 ? null : i;
          perubahan++;
        }
      }
      final r = posisi * (data[i + 1].close / data[i].close - 1) - biaya;
      ekuitas *= 1 + r;
      returns.add(r);
      kurva.add(ekuitas);
    }
    tutup(n - 1);

    return HasilBacktest(
      ekuitas: kurva,
      returnPeriode: returns,
      transaksi: transaksi,
      returnBeliTahan: data[n - 1].close / data[mulai].close - 1,
      jumlahPerubahanPosisi: perubahan,
    );
  }
}
