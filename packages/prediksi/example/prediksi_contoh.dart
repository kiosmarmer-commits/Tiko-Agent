// Contoh pemakaian paket `prediksi` pada data sintetis (bukan data pasar nyata).
//
// Jalankan dari folder paket:
//   dart pub get
//   dart run example/prediksi_contoh.dart

import 'dart:math' as math;

import 'package:prediksi/prediksi.dart';

/// Membuat 400 candle harian acak dengan sedikit tren naik.
List<Candle> buatDataSintetis({int jumlah = 400, int benih = 7}) {
  final rnd = math.Random(benih);
  final out = <Candle>[];
  var harga = 100.0;
  final awal = DateTime.utc(2025, 1, 1);
  for (var i = 0; i < jumlah; i++) {
    final ret = 0.0004 + 0.012 * (rnd.nextDouble() * 2 - 1);
    final buka = harga;
    harga *= 1 + ret;
    out.add(Candle(
      waktu: awal.add(Duration(days: i)),
      open: buka,
      high: math.max(buka, harga) * 1.003,
      low: math.min(buka, harga) * 0.997,
      close: harga,
      volume: 1000 + rnd.nextDouble() * 500,
    ));
  }
  return out;
}

void main() {
  final data = buatDataSintetis();
  final hariIni = DateTime.utc(2026, 11, 12);

  // 1. Metode berbasis candle.
  final metodeCandle = <MetodePrediksi>[
    const AnalisisTeknikal(),
    const RegresiTren(),
    const Arima(),
    const MonteCarlo(jumlahJalur: 1000),
    MetodeML.hutan(jumlahPohon: 30),
    const DowTheory(),
    const ElliottWave(),
    const IndeksTakutSerakahLokal(),
  ];
  print('=== Metode berbasis candle ===');
  for (final m in metodeCandle) {
    print(m.analisis(data));
  }

  // 2. Metode berbasis tanggal (siklus).
  print('\n=== Siklus ===');
  final siklus = <MetodeSiklus>[
    SiklusBenner(),
    const SiklusPeriodik.kondratiev(),
    const SiklusPeriodik.juglar(),
    HalvingBitcoin(),
  ];
  final sinyalSiklus = [for (final s in siklus) s.pada(hariIni)];
  sinyalSiklus.forEach(print);

  // 3. Makro dan sentimen (data diisi sendiri; angka di bawah hanya contoh).
  print('\n=== Makro ===');
  const papan = PapanMakro();
  final makro = papan.gabungan(const DataMakro(
    hasilPanjang: 4.2,
    hasilPendek: 4.6,
    pmi: 49.5,
    vix: 18,
    indeksTakutSerakah: 62,
  ));
  print(makro);

  // 4. Ensemble: gabungkan semuanya.
  print('\n=== Ensemble ===');
  final ensemble = Ensemble(metodeCandle, nama: 'Ensemble Semua');
  final hasil = ensemble.hitung(
    data,
    tambahan: [...sinyalSiklus, makro],
  );
  print(hasil);

  // 5. Backtest satu metode (interval besar supaya cepat).
  print('\n=== Backtest ===');
  const bt = Backtest(mulai: 120, interval: 5, biayaPerTransaksi: 0.001);
  print(bt.jalankan(const AnalisisTeknikal(), data));

  // 6. Manajemen risiko: ukuran posisi dengan stop ATR.
  print('\n=== Risiko ===');
  final atr = Indikator.atr(data).last;
  final masuk = data.last.close;
  final stop = ManajemenRisiko.stopLossAtr(hargaMasuk: masuk, atr: atr);
  final unit = ManajemenRisiko.ukuranPosisi(
    modal: 10000000,
    risikoPersen: 1,
    hargaMasuk: masuk,
    hargaStop: stop,
  );
  print('Masuk ${masuk.toStringAsFixed(2)}, stop ${stop.toStringAsFixed(2)}, '
      'unit ${unit.toStringAsFixed(2)}');
}
