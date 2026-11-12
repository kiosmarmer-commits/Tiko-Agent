---
name: prediksi-pasar
description: Analisis prediksi pasar menggunakan metode teknikal, siklus, statistik, ML edukasi, ensemble, backtest, dan manajemen risiko dari paket prediksi.
triggers: ["prediksi", "sinyal", "analisis teknikal", "backtest", "siklus", "benner", "halving", "elliott", "risiko", "stop loss", "kelly", "ensemble", "RSI", "MACD"]
tools: [prediksi_teknikal, prediksi_ensemble, prediksi_siklus, prediksi_backtest, prediksi_risiko]
version: 1
status: draft
---

## Tujuan

Memberikan sinyal dan analisis pasar berbasis metode yang dapat dijelaskan (bukan black-box murni),
lalu selalu dilengkapi konteks risiko. Hasilnya adalah **alat analisis/edukasi**, bukan saran keuangan.

## Kapan dipakai

- User meminta prediksi / sinyal / analisis teknikal / backtest / siklus pasar.
- User menanyakan ukuran posisi, stop-loss, atau Kelly.
- Ada data candle (OHLCV) atau user bersedia memakai data contoh.

## Alur kerja yang disarankan

1. **Pastikan data**
   - Jika user memberi daftar harga/candle → pakai langsung.
   - Jika tidak ada data → minta data atau jelaskan bahwa analisis butuh candle; jangan mengarang harga nyata.

2. **Pilih tool**
   - Sinyal cepat / multi-metode → `prediksi_ensemble`
   - Hanya teknikal → `prediksi_teknikal`
   - Hanya siklus waktu → `prediksi_siklus`
   - Evaluasi historis → `prediksi_backtest`
   - Ukuran posisi / stop → `prediksi_risiko`

3. **Sampaikan hasil**
   - Arah (`beli` / `jual` / `tahan`), skor (-1..+1), tingkat kesepakatan (jika ensemble).
   - Catatan singkat dari metode.
   - Selalu sebutkan batasan (data terbatas, metode edukasi, bukan jaminan).

4. **Risiko**
   - Setelah sinyal, tawarkan perhitungan stop ATR + ukuran posisi jika relevan.
   - Ingatkan: past performance ≠ future results.

## Format jawaban yang baik

- Ringkas dulu (1–2 kalimat kesimpulan).
- Lalu detail skor / kesepakatan / rincian metode.
- Akhiri dengan peringatan edukasi + tawaran langkah berikutnya (backtest / risiko / data lain).

## Larangan

- Jangan mengklaim prediksi pasti untung.
- Jangan mengeksekusi order / menghubungkan ke exchange tanpa konfirmasi eksplisit user dan tool yang sesuai.
- Jangan mengisi data makro/fundamental fiktif seolah data nyata tanpa memberi tahu user.
