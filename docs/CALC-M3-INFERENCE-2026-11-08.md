# Laporan M3 `agent_calc` (task hasil inferensi)

- **Tanggal**: 2026-11-08
- **CI**: menunggu verifikasi pada commit laporan ini
- **Cakupan**: TASK-CALC-21..23 **hasil inferensi** — definisi asli TASK-CALC-21..35 tidak tersedia di repo (lihat laporan M2, bagian Sisa); dengan persetujuan pemilik proyek, scope disimpulkan dari hint di repo.

## Dasar inferensi

| Sumber | Hint | Task turunan |
|---|---|---|
| Laporan M2 bagian "Sisa" | "Runtime Tiko async ... menyusul saat ada kebutuhan integrasi" — tool `calc` runtime masih mengevaluasi sinkron di isolate utama | TASK-CALC-21 |
| TASK-CALC-11 (runner golden) + `fixtures/golden_verified.json` | fixture golden masih hanya kasus M0 (G-MAT-001..016) | TASK-CALC-22 |
| Skema tool `calc` (scale/rounding/locale) vs `DirectCommandDispatcher` | skema tool mendukung parameter, tetapi direct command hanya menggabung argumen menjadi ekspresi | TASK-CALC-23 |

Penomoran 21..23 bersifat sementara; bila definisi asli muncul, tabel ini dipetakan ulang tanpa mengubah perilaku kode.

## TASK-CALC-21: tool calc runtime via CalcSandbox

- `CalcTool.run` (packages/agent_tools) kini mengevaluasi lewat `CalcSandbox.evaluate` (isolate terpisah), bukan `CalcEngine` sinkron.
- Timeout keras dari `CalcLimits.timeoutMs` (default 2000 ms) berlaku di seluruh jalur runtime (agent loop, direct command, daemon) — beban besar tidak pernah menggantung runtime.
- Kontrak keluaran JSON tidak berubah (paritas hasil engine/sandbox sudah diuji di M2); semua test `calc_tool_test` lama tetap hijau.
- Test baru: fungsi domain M1 lewat tool (`pmt`), beban berat `fact(5000)` dalam timeout default, dan `CalcLimits(timeoutMs: 0)` -> `CALC_E_TIMEOUT`.

## TASK-CALC-22: golden fixtures domain M1

- 13 kasus `eval` baru di `fixtures/golden_verified.json` (total 29): satuan (G-UNI), keuangan (G-FIN), statistik (G-STA), tanggal (G-DAT).
- Nilai harapan diverifikasi independen dari kode Dart (simulasi BigInt JS), sesuai prinsip runner golden CALC-TST-01.
- Contoh: `pmt(0.01, 12, 100000)` = `8884.878867834171`; `amortisasi(0.01, 12, 1000000)` = `66185.464140100484`; `annuity_fv(0.01, 12, 100)` = `1268.250301319697`; `var_s(2,4,4,4,5,5,7,9)` = `4.571428571429`; `percentile(1,2,3,4,90)` = `3.7`; `date_diff(20260101, 20260301)` = `59`.

## TASK-CALC-23: flag CLI untuk `tiko calc`

- `DirectCommandDispatcher` kini mengenali flag opsional sebelum ekspresi: `--scale=N` (0..50), `--rounding=MODE` (half_even/half_up/down/up/floor/ceiling), `--locale=id|en`.
- Contoh: `tiko calc --scale=4 2/3` -> `0.6667`; `tiko calc --locale=en 1,500.50*2` -> `3001`.
- Validasi ketat: flag/nilai tidak dikenal -> pesan penggunaan (exit 2), tanpa pernah dievaluasi; argumen tanpa flag tidak berubah perilakunya.

## Temuan desain (pencatat untuk task berikutnya)

- `maxExpressionLength` = 2000 karakter membuat statistik "100k titik" (disebut laporan M0 sebagai motivasi sandbox) tidak terjangkau lewat input ekspresi; bila dibutuhkan, sediakan jalur API data terpisah (bukan ekspresi) — jangan hanya menaikkan batas panjang.

## Sisa

- Pengukuran biaya spawn di Termux nyata (bagian device TASK-CALC-36) tetap menunggu perangkat fisik.
- TASK-CALC-24..35 tetap menunggu definisi asli pemilik proyek.

## Commit

- `9bd933b` feat(calc): TASK-CALC-21 (inferensi) tool calc runtime via CalcSandbox
- `87417c5` feat(calc): TASK-CALC-22 (inferensi) golden fixtures domain M1
- `0b47bf4` feat(calc): TASK-CALC-23 (inferensi) flag CLI scale/rounding/locale untuk tiko calc
- (commit ini) docs(calc): laporan M3 (task hasil inferensi)

## Test

- Baru: 3 test di `calc_tool_test.dart`, 4 test di `direct_commands_test.dart`, 13 kasus golden.
- Semua test eksisting (engine, sandbox, golden, evaluator, locale, rewrite, registry, ssrf, direct command) tidak diubah ekspektasinya dan harus tetap hijau.
