# prediksi

Kumpulan metode prediksi pasar/ekonomi dalam **Dart murni** (tanpa dependensi runtime).
Setiap metode menghasilkan `Sinyal` yang seragam: arah (`beli` / `jual` / `tahan`) dan skor
-1.0 (sangat bearish) sampai +1.0 (sangat bullish), sehingga semua metode bisa dibandingkan
dan digabung lewat `Ensemble`.

> **Peringatan:** alat analisis dan edukasi, **bukan saran keuangan**. Tidak ada metode di sini yang
> terbukti memprediksi pasar secara konsisten. Hasil backtest bagus tidak menjamin hasil nyata.

## Status algoritma (v0.1.1)

| Modul | Status | Catatan |
|-------|--------|---------|
| Core (`Candle`, `Sinyal`, `MetodePrediksi`) | Lengkap & valid | Kontrak seragam |
| Technical (`AnalisisTeknikal` + indikator) | Lengkap | RSI, MACD, Bollinger, SMA |
| Cycles (Benner, Halving, Periodik, Gabungan) | Lengkap | Tabel Benner perlu diverifikasi sumber asli |
| Stats (RegresiTren, ARIMA(p,d,0), MonteCarlo) | Lengkap | ARIMA tanpa komponen MA |
| ML (KNN, Pohon, Random Forest, LSTM edukasi) | Lengkap | LSTM manual, lambat, untuk edukasi |
| Pola (ZigZag, Dow, Elliott heuristik) | Lengkap | Elliott sangat subjektif |
| Fundamental (PER/PBV/PEG/Graham/DCF) | Lengkap | Asumsi sensitif |
| Konsensus (Delphi, Pasar Prediksi) | Lengkap | |
| Makro & Sentimen | Lengkap | Data diisi pemakai |
| Ensemble | Lengkap | Rata-rata berbobot + kesepakatan |
| Backtest walk-forward | Lengkap | Ada biaya transaksi |
| Manajemen Risiko | Lengkap | ATR stop, Kelly, VaR, ES, Sharpe, Sortino, max DD |

Semua file sudah diekspor lewat `lib/prediksi.dart`. Tidak ada `TODO` / `UnimplementedError` di sumber.

## Instalasi (standalone)

```bash
cd packages/prediksi
dart pub get
dart analyze
dart test
dart run example/prediksi_contoh.dart
```

## Integrasi ke Tiko-Agent

Lihat `docs/INTEGRASI-PREDIKSI-TIKO.md` di root bundle ini.

## Contoh singkat

```dart
import 'package:prediksi/prediksi.dart';

final data = <Candle>[/* OHLCV kamu */];

// Satu metode
print(const AnalisisTeknikal().analisis(data));

// Siklus
print(SiklusBenner().pada(DateTime.now()));

// Ensemble
final ens = Ensemble([
  const AnalisisTeknikal(),
  const RegresiTren(),
  MetodeML.hutan(),
]);
print(ens.hitung(data, tambahan: [SiklusBenner().pada(DateTime.now())]));

// Backtest
print(const Backtest(mulai: 120, interval: 5).jalankan(const AnalisisTeknikal(), data));
```

## Batasan yang perlu diketahui

- **Benner Cycle:** tabel tahun bawaan adalah versi yang beredar luas; belum diverifikasi ke sumber asli (1875).
- **Siklus periodik:** tahun acuan puncak hanya perkiraan kasar.
- **ARIMA:** tanpa komponen MA (sebenarnya AR + differencing).
- **Monte Carlo:** bergantung pada mean & volatilitas historis.
- **Machine learning:** rawan overfitting; LSTM ditulis manual (edukasi) dan relatif lambat.
- **Elliott Wave:** versi heuristik berbasis aturan baku.
- **Backtest:** eksekusi pada close sinyal (sedikit optimistis), ada biaya tetap, tanpa slippage ekstra / pajak.
- **Tidak ada pengambilan data:** paket ini tidak mengakses internet.

## Struktur

```
packages/prediksi/
  pubspec.yaml
  analysis_options.yaml
  README.md
  example/prediksi_contoh.dart
  lib/prediksi.dart
  lib/src/{core,technical,cycles,stats,ml,macro,pola,fundamental,konsensus,ensemble,backtest,risiko}/
  test/*.dart
```
