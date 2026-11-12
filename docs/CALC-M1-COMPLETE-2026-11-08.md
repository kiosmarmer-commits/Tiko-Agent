# Laporan Milestone M1: agent_calc

Tanggal: 2026-11-08
Status: SELESAI - CI hijau di HEAD (`e057572`)
Cakupan: TASK-CALC-12..20 (satuan, keuangan, statistik, tanggal)

## Ringkasan

M1 melengkapi kalkulator eksak `agent_calc` dengan empat domain baru.
Semua jalur non-transendental tetap eksak lewat `Dec` (BigInt); tidak ada
pengecualian mentah yang bocor; galat selalu berkode kontrak
`CALC_E_*`. Meta algo tetap `calc/1.0.0` (perubahan aditif, tanpa
breaking pada kontrak JSON).

## TASK-CALC-12: Konversi satuan

- Bentuk khusus `convert(nilai, dari, ke)`; argumen satuan adalah ident
  mentah (ditangani khusus di evaluator sebelum lookup fungsi), mis.
  `convert(5, km, m)`.
- Tabel faktor eksak per family: panjang (mm..mil_laut), massa
  (mg..lb, termasuk ons = 100 g), waktu, volume, luas, data (SI + biner
  kib/mib/gib/tib), kecepatan (km/jam basis).
- Suhu (c/f/k) afine lewat pivot celcius, eksak pada skala konteks.
- Galat: `CALC_E_UNIT_MISMATCH` untuk satuan tidak dikenal atau beda
  family; `CALC_E_SYNTAX` untuk arity/nama salah.

## TASK-CALC-13..15: Keuangan

- `pmt(i, n, pv)` angsuran anuitas: eksak `pv*i*g/(g-1)` dengan
  `g = (1+i)^n` via `powInt` (satu pembagian pada skala konteks).
- `annuity_fv(i, n, pmt)` dan `annuity_pv(i, n, pmt)` eksak.
- `amortisasi(i, n, pv)` total bunga sepanjang tenor (`pmt*n - pv`).
- `sisa(i, n, pv, k)` saldo pinjaman setelah k angsuran.
- `irr(cf0, cf1, ...)` numerik: bisection NPV double 200 iterasi pada
  rentang [-99%, 1000%]; menandai `approximate`; tanpa akar ->
  `CALC_E_NO_CONVERGENCE` (arus kas harus berubah tanda).
- Batas: n bulat 1..12000; guard digit hasil via `maxResultDigits`.

## TASK-CALC-16..17: Statistik deskriptif

- `mean`, `median`, `var_p`, `var_s`, `stdev_p`, `stdev_s`,
  `percentile(data..., p)`.
- Dua lolos eksak via Dec; Welford tidak diperlukan karena aritmetika
  sudah eksak. `stdev_*` memakai `sqrtAt` (Newton BigInt).
- `percentile`: interpolasi linear rank = p/100*(n-1), p dibatasi
  0..100; data dibatasi `maxListLength`.

## TASK-CALC-18..20: Tanggal sipil

- Representasi tanggal: bilangan bulat YYYYMMDD (tahun 1..9999),
  kalender sipil proleptik tanpa zona waktu/DST.
- Algoritma `days_from_civil` / `civil_from_days` (Hinnant), epoch
  1970-01-01, murni integer.
- `date_diff(a, b)` selisih hari; `date_add(ymd, hari)`;
  `date_add_months(ymd, bulan)` dengan clamp akhir bulan
  (31 Jan + 1 bulan -> 28 Feb); `day_of_week` ISO (1=Senin..7=Minggu);
  `is_leap_year`; `days_in_month`.
- Validasi ketat (kabisat, hari per bulan, rentang tahun) ->
  `CALC_E_DOMAIN`.

## Perbaikan menyertai (fix-forward)

- Regex sufiks pengali di `locale_numbers.dart`: grup angka kini wajib
  diakhiri digit, sehingga koma pemisah argumen tidak ikut tercerna
  (`convert(300, k, c)` sebelumnya dipotong menjadi
  `convert(300000, c)`). Kasus M0 (`2 juta`, `1,5 juta`, `3k`)
  tidak berubah; regresi diuji di `locale_numbers_test.dart`.
- Koreksi ekspektasi test `100 + convert(2, km, m)` -> `2100`.

## TASK yang ditunda

- TASK-CALC-09 (sandbox isolate untuk evaluasi): tetap defer; belum ada
  operasi berat yang membutuhkan isolasi proses di M0/M1.

## Commit

- `709db66` feat(calc): TASK-CALC-12 konversi satuan convert() eksak
- `e296469` feat(calc): TASK-CALC-13..15 keuangan: anuitas, amortisasi, IRR
- `64fbf9f` feat(calc): TASK-CALC-16..17 statistik deskriptif eksak
- `9e22a9c` feat(calc): TASK-CALC-18..20 tanggal sipil Hinnant
- `e057572` fix(calc): sufiks locale tidak mencerna koma argumen; koreksi test

## Test

- Baru: `test/units/units_test.dart` (9), `test/finance/finance_test.dart`
  (9), `test/stats/stats_test.dart` (7),
  `test/dates/civil_date_test.dart` (6), plus regresi locale (1).
- Semua test eksisting (engine, dec, golden, evaluator, locale, rewrite,
  registry, ssrf) tetap hijau.

## Contoh

- `tiko calc "convert(5, km, m)"` -> `5000`
- `tiko calc "convert(300, k, c)"` -> `26.85`
- `tiko calc "pmt(0.01, 12, 100000)"` -> `8884.878867834171`
- `tiko calc "amortisasi(0.01, 12, 1000000)"` -> `66185.464140100484`
- `tiko calc "var_s(2, 4, 4, 4, 5, 5, 7, 9)"` -> `4.571428571429`
- `tiko calc "date_diff(20260101, 20260301)"` -> `59`
- `tiko calc "day_of_week(20261108)"` -> `7`
- `tiko calc "irr(-1000, 1100)"` -> sekitar `0.1` (approximate)
