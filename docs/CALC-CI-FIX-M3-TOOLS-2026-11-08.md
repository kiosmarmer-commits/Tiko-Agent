# Laporan Fix CI: builtin.dart agent_tools (pasca-M3)

Tanggal: 2026-11-08
Status: SELESAI - CI hijau di HEAD (`0d403fb`)
Cakupan: perbaikan gerbang analyze strict untuk tree M3 inferensi

## Kronologi

Setelah M3 (TASK-CALC-21..23) tergabung, HEAD `7ec1e71` merah pada job
"Dart analysis, tests and CLI smoke" di step Static analysis:
4 error, 1 warning, 1 info - semuanya di
`packages/agent_tools/lib/src/builtin.dart`. Job Flutter tetap hijau.
Karena analyze berjalan dengan `--fatal-infos --fatal-warnings`,
seluruh job gagal sebelum step test sempat berjalan; test baru M3
(calc_tool, flag CLI, 13 golden fixtures) belum pernah tereksekusi
di CI pada tree tersebut.

## Diagnosis

- `UNDEFINED_METHOD` + kaskade 3x `UNCHECKED_USE_OF_NULLABLE_VALUE`
  (`response.statusCode` x2, `response.headers['location']` x1):
  kode memakai bare `IOClient(...)` padahal import menggunakan
  prefiks (`import 'package:http/io_client.dart' as io;`), sehingga
  type resolution rusak dan response dianggap nullable.
- `UNUSED_IMPORT` pada `io_client.dart` (prefiks `io` tak pernah
  dipakai) - warning fatal.
- `UNNECESSARY_BRACE_IN_STRING_INTERPS` pada interpolasi
  `'${content}$trailer'` di ListDirTool - info fatal.

## Perbaikan

Dua edit minimal pada builtin.dart (tanpa perubahan perilaku):

1. `IOClient(ssrf.pinnedHttpClient())` ->
   `io.IOClient(ssrf.pinnedHttpClient())`
   (menghapus UNDEFINED_METHOD, ketiga kaskade nullable, dan
   UNUSED_IMPORT sekaligus).
2. `'${content}$trailer'` -> `'$content$trailer'`
   (menghapus UNNECESSARY_BRACE_IN_STRING_INTERPS).

## Verifikasi

CI run #132 pada commit fix selesai SUCCESS (~1,5 menit), kedua job
hijau: Dart (Static analysis strict, test semua workspace member,
CLI smoke, compile 3 executable, daemon smoke) dan Flutter
(analysis, test, web build). Dengan ini seluruh suite test tree M3
pertama kalinya terverifikasi hijau di CI, termasuk:

- `calc_tool_test.dart`: CalcTool mengevaluasi lewat CalcSandbox
  isolate (TASK-CALC-21), flag `--scale/--rounding/--locale` pada
  `direct_commands.dart` (TASK-CALC-23),
- 13 golden fixtures domain M1 (TASK-CALC-22): pmt, amortisasi,
  annuity_fv, var_s, percentile, date_diff, convert, dll.

## Status milestone agent_calc

- M0 engine eksak inti: hijau (`7afc4c4`, laporan terpisah).
- M1 satuan/keuangan/statistik/tanggal (TASK-CALC-12..20): hijau
  (`9e22a9c` + fix `e057572`, laporan terpisah).
- M2 sandbox isolate + benchmark (TASK-CALC-09/36): hijau
  (laporan `CALC-M2-TASK-09-36-COMPLETE-2026-11-08.md`).
- M3 inferensi CalcTool + golden + flag CLI (TASK-CALC-21..23):
  hijau (laporan `CALC-M3-INFERENCE-2026-11-08.md`).

## Commit

- `7ec1e71` (gabungan M3, sesi sebelumnya): CalcTool via sandbox,
  golden fixtures, flag CLI - analyze merah, diperbaiki di bawah.
- `0d403fb` fix(tools): prefiks io.IOClient dan interpolasi tanpa
  brace tak perlu (CI analyze) - hijau.
