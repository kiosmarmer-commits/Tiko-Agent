# Laporan M2 (task 09 & 36): Sandbox Isolate + Benchmark

Tanggal: 2026-11-08
Status: SELESAI - CI hijau pada HEAD
Cakupan: TASK-CALC-09 (sandbox isolate + timeout dapat dibatalkan) dan
TASK-CALC-36 (tool benchmark biaya spawn, bagian yang dapat dikerjakan
tanpa perangkat Termux fisik).

## TASK-CALC-09: CalcSandbox

- `CalcSandbox.evaluate(...)` (`lib/src/calc_sandbox.dart`): evaluasi
  berjalan di isolate terpisah; hasil `CalcResult` dikirim langsung
  melintasi port (objek immutable, sendable sejak Dart 2.15).
- Timeout dari `CalcLimits.timeoutMs` (default 2000 ms) membatalkan
  isolat secara keras (`Isolate.kill`) dan mengembalikan galat
  `CALC_E_TIMEOUT` - tidak pernah angka tebakan (P5).
- Kegagalan internal isolat dipetakan ke `CALC_E_SYNTAX` sandbox.
- Listener dipasang SEBELUM `Isolate.spawn` agar hasil yang datang
  sangat cepat tidak hilang; isolat selalu dibunuh di `finally`.
- API async opsional; jalur sinkron `CalcEngine` tidak berubah dan
  runtime Tiko (tool `calc` yang sinkron) belum dialihkan - sandbox
  siap dipakai pemanggil async saat integrasi itu dibutuhkan.

## TASK-CALC-36 (bagian tool): benchmark biaya spawn

- `packages/agent_calc/tool/bench_isolate.dart`: membandingkan
  evaluasi langsung vs sandbox (ekspresi ringan) dan mencetak
  p50/p95 mikrodetik.
- Pengukuran di Termux tinggal dijalankan:
  `cd packages/agent_calc && dart run tool/bench_isolate.dart 200`.

## Pengujian

- `test/calc_sandbox_test.dart` (5 test): paritas hasil dengan engine
  langsung, galat berkode melewati batas isolate, penerusan parameter
  scale/locale, operasi berat (`fact(5000)`, 16326 digit) selesai
  dalam batas default, dan timeout deterministik
  (`CalcLimits(timeoutMs: 0)` - round-trip isolate selalu kalah dari
  timer 0 ms) menghasilkan `CALC_E_TIMEOUT`.

## Sisa

- Definisi TASK-CALC-21..35 (jika ada di rencana awal) belum tersedia
  di repo; menunggu pemilik proyek.
- Runtime Tiko async + pengukuran Termux nyata menyusul saat ada
  kebutuhan integrasi.
