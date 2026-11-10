# Laporan M0 `agent_calc` Selesai

- **Tanggal**: 2026-11-08
- **CI**: hijau pada commit `7afc4c4` (workflow `ci`, job "Dart analysis, tests and CLI smoke" sukses; Flutter client validation juga sukses)
- **Cakupan**: Milestone M0 — fondasi kalkulator eksak (TASK-CALC-01 sampai 11)

## Status tugas M0

| ID | Tugas | Status |
|---|---|---|
| TASK-CALC-01 | Audit SafeMath / DirectCommandDispatcher, keputusan migrasi | selesai |
| TASK-CALC-02 | Paket `agent_calc` + CI (format, analyze, test) | selesai |
| TASK-CALC-03 | `Dec` (BigInt), mode pembulatan, `divide` eksplisit | selesai |
| TASK-CALC-04 | Tokenizer, parser recursive descent, AST, batas | selesai |
| TASK-CALC-05 | Evaluator, fungsi dasar, `sqrt` BigInt, konstanta | selesai |
| TASK-CALC-06 | Locale id/en, sufiks (`rb`, `juta`, ...), warning ambigu | selesai |
| TASK-CALC-07 | Rewrite bahasa Indonesia R1..R6 + semantik persen | selesai |
| TASK-CALC-08 | Kontrak tool `calc` (skema, hasil, kode galat) | selesai |
| TASK-CALC-09 | Sandbox isolate + timeout dapat dibatalkan | **ditunda** (lihat bawah) |
| TASK-CALC-10 | Integrasi runtime Tiko (`ToolSpec`, risk, direct command) | selesai |
| TASK-CALC-11 | Runner golden + fixture terverifikasi | selesai |

`tiko calc "15% dari 2 juta"` menghasilkan `300000` tanpa LLM (smoke CI).

## Perbaikan pada commit `7afc4c4`

1. **Regex escape**: raw-string Dart di `rewrite_id.dart` dan `locale_numbers.dart` memakai backslash tunggal (`\s` bukan `\\s`); backslash ganda membuat semua pola R1..R6 tidak pernah cocok.
2. **R6 asosiatif kiri**: pola operator kata (`kali`/`dibagi`/`tambah`/`kurang`/`pangkat`) kini memakai grup kiri greedy sehingga split terjadi pada operator **terakhir**, lalu operand kiri ditulis ulang rekursif. Hasil: `2 kali 3 kali 4` → `((2)*(3))*(4)` (sesuai tes).
3. **Guard grup akar**: pola R5 (`akar dari X`) hanya punya satu grup tangkapan; pembacaan grup 2 kini dijaga `groupCount` sehingga tidak ada RangeError.
4. **Galat berkode di evaluator**: `FormatException` mentah dari `Dec` (pembagi nol, akar negatif) dipetakan menjadi `CalcException` berkode (`CALC_E_DIV_ZERO`, `CALC_E_DOMAIN`, fallback `CALC_E_SYNTAX`) — P5 "gagal terang".
5. **ShellTool**: pemisah argumen `RegExp(r'\s+')` (sebelumnya `r's+'` yang salah) sehingga split token perintah benar.
6. **Penyelarasan tes kontrak**: keluaran JSON `CalcTool` dikompak (`"value":"20"`) dan ekspektasi tes registry/ssrf diperbarui.

## Keputusan desain M0

- **DEC-OPEN-01 ditetapkan**: `round()` default **half_up** (kebiasaan sekolah); tersedia `round_half_even` dan `round_half_up` eksplisit.
- Presedensi: `^` asosiatif kanan, minus unary di bawah `^` (`-2^2 = -4`), di atas `*`/`/`.
- Persen `+/-` memakai basis operand kiri dengan warning `PERCENT_BASE_LEFT`.
- Angka ambigu (`1.500` locale id): non-strict → ribuan + `W_AMBIGUOUS_NUMBER`; strict → `CALC_E_AMBIGUOUS_NUMBER`.

## TASK-CALC-09 ditunda — alasan

M0 belum memuat operasi berat yang membutuhkan pembatalan keras: batas pra-cek (panjang ekspresi 2000, kedalaman AST 64, pangkat/faktorial terbatas) sudah aktif dan dieksekusi di isolate utama (< 5 ms p95 target). Sandbox isolate (`Isolate.spawn` + kill, VERIFY-04) akan dikerjakan bersama M1 saat ada beban nyata (statistik 100k titik, backtest) agar timeout dapat diuji bermakna dan benchmark Termux (TASK-CALC-36) mengukur biaya spawn secara realistis.

## Langkah berikutnya (M1)

TASK-CALC-12..20: satuan (`calc_units`), TVM/amortisasi/IRR, statistik Welford, tanggal sipil. Menunggu konfirmasi sebelum mulai.
