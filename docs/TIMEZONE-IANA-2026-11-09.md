# Laporan: Dukungan Zona IANA Penuh + DST untuk Scheduler — 2026-11-09

## 1. Masalah

Sebelum perbaikan ini, `packages/agent_scheduler` menghitung waktu eksekusi cron dengan offset tetap (helper `_toWallTime`/`_offsetFor` di `src/cron.dart`):

1. **Zona bernama hanya offset tetap.** `WIB` (+07) dan `WITA` (+08) diterima, tetapi nama zona IANA seperti `Asia/Jakarta` atau `America/New_York` ditolak `FormatException` — test lama bahkan menegaskan `America/New_York` harus gagal.
2. **DST tidak dihitung.** Untuk zona dengan daylight saving, waktu dinding bergeser 1 jam dua kali setahun; ekspresi cron seperti `0 3 * * *` (pukul 03:00 waktu lokal) dieksekusi pada instant UTC yang salah selama DST.
3. **Scan `nextAfter` rentan.** Pencarian instant berikutnya menambah waktu dengan offset tetap, sehingga jam yang dilompat (spring-forward) atau ambigu (fall-back) dihitung keliru.

## 2. Desain

### 2.1 Ketergantungan baru: `package:timezone`

- `timezone` 0.10.2 (data IANA 2025c), lisensi BSD-2, terdaftar sebagai **DEP-21** di `docs/08-REGISTRI-DEPENDENSI.md`.
- Pra-v1 (K-6): seluruh akses dikurung di interface `final class Tz` (`src/timezones.dart`) sehingga mudah diganti; pin `^0.10.0` menghindari breaking 0.11 (pindah ke dart-lang/labs, `Location.offset` berubah int → Duration).

### 2.2 Kelas `Tz` (`src/timezones.dart`)

- `resolve(name)` — trim; nama kosong atau lebih dari 64 karakter → `FormatException`; `tzdata.initializeTimeZones()` dijalankan lazy sekali; `tz.getLocation` dibungkus try/catch → `FormatException` fail-closed (nama tidak pernah diterima diam-diam).
- `wallFromUtc(instant, timezone)` — `TZDateTime.from(instant.toUtc(), loc)` → `DateTime.utc` naive (waktu dinding).
- `utcFromWall(wall, timezone)` — `TZDateTime(loc, y, m, d, h, min)` → instant UTC.

### 2.3 Konvensi DST

- **Fold** (jam ambigu saat DST berakhir): pilih kemunculan **pertama** — jadwal at-most-once per hari.
- **Gap** (jam dilompat saat DST mulai): dinormalisasi maju oleh `TZDateTime`; kandidat di gap tetap menghasilkan instant valid.

### 2.4 `Cron.matchesAt` dan `nextAfter` (`src/cron.dart`)

- `matchesAt` mengonversi instant ke waktu dinding sekali via `Tz.wallFromUtc`, lalu mencocokkan field menit/jam/hari seperti sebelumnya.
- `nextAfter` ditulis ulang: enumerasi kandidat per hari (maksimum `maxScanMinutes ~/ 1440 + 1` hari ke depan). Untuk setiap hari yang cocok, dibangun `wall = DateTime.utc(y, m, d, hour, minute)`, dikonversi `Tz.utcFromWall(wall, timezone)`, dan dikembalikan bila instant setelah `fromUtc` dan tidak melewati `deadline`. Helper offset tetap `_toWallTime`/`_offsetFor` dihapus.

### 2.5 Tool & runtime

- Deskripsi parameter `timezone` pada `schedule_tool.dart` diperbarui: "Nama zona IANA penuh, mis. Asia/Jakarta atau America/New_York; DST dihitung otomatis".
- Semua logika zona terkurung di `agent_scheduler`; `agentd`, `agent_cli`, `tiko`, dan `agent_gateway` tidak menyandikan nama zona — tidak ada perubahan API di luar paket.

## 3. Matriks test

| Berkas | Perubahan |
|---|---|
| `packages/agent_scheduler/test/timezone_test.dart` | Ditulis ulang penuh: `Tz.resolve` valid/tidak valid; roundtrip `wallFromUtc`/`utcFromWall` Jayapura (offset +09 gaya lama) dan Berlin (IANA); `matchesAt` WIB/WITA; DST AS & EU; `nextAfter` spring-forward; `JobStore.add` America/New_York; tool menulis zona valid dan menolak zona tidak valid tanpa menulis |
| `packages/agent_scheduler/test/scheduler_test.dart` | Asersi lama `America/New_York` → `throwsFormatException` diganti: `nextAfter` dengan zona IANA mengembalikan instant UTC (dari 2026-11-07 02:30Z → 2026-11-07 12:00Z) |

Kasus DST utama yang diuji:

- AS (`0 3 * * *`, America/New_York): 2026-03-08 07:00Z cocok (03:00 EDT setelah spring-forward), 2026-03-07 08:00Z cocok (03:00 EST), 2026-02-08 07:00Z tidak cocok.
- EU (`0 3 * * *`, Europe/Berlin): 2026-03-29 01:00Z cocok (03:00 CEST), 2026-03-28 02:00Z cocok (03:00 CET), 2026-03-29 02:00Z tidak cocok.
- `nextAfter` spring-forward NY (`0 9 * * *`): dari 2026-03-07 12:00Z → 2026-03-07 14:00Z (09:00 EST); dari 2026-03-08 11:00Z → 2026-03-08 13:00Z (09:00 EDT).
- Zona tidak valid (`Mars/Olympus`) gagal `FormatException` tanpa menulis job.

## 4. Keterbatasan & tindak lanjut

1. **Fold at-most-once**: jam ambigu dipilih kemunculan pertama; jadwal tidak pernah dieksekusi dua kali pada hari yang sama. Semantik "kedua kemunculan" tidak didukung (tidak ada kebutuhan saat ini).
2. **Data tzdata terkunci versi paket** (`timezone` 0.10.2 → IANA 2025c): perubahan aturan zona di masa depan mengikuti rilis paket.
3. Offset pendek gaya lama (`WIB`, `WITA`, `+09`) tetap didukung untuk kompatibilitas mundur.

## 5. Jejak audit

- Feat: 7 berkas (`pubspec.yaml`, `src/timezones.dart` baru, `src/cron.dart`, `agent_scheduler.dart`, `src/schedule_tool.dart`, dua berkas test) — commit `6ce4bb2`.
- Registri dependensi: baris DEP-21 ditambahkan (AGD-08 §2), status ✅ dengan catatan pra-v1/K-6.
- Verifikasi: CI GitHub Actions pada HEAD (`dart analyze --fatal-infos --fatal-warnings` + test seluruh workspace member + smoke CLI/agentd).
