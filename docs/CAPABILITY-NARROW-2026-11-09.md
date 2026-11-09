# Perbaikan: Capability Token Sempit Terikat Sumber Daya

- Tanggal: 2026-11-09
- Repo: `kiosmarmer-commits/Tiko-Agent` (branch `main`)
- Bloker: "narrow resource-bound capability tokens" dari `TIKO-REPAIR-STATUS-2026-11-07.md`
- Jejak audit: feat `554c72b` ("feat(runtime): capability token sempit terikat sumber daya") + fix `9a86c6f` (helper `_withinApprovedBytes` yang tertinggal).

## Masalah

Sebelum perbaikan ini, setiap approval tool menerbitkan capability token dengan bentuk generik:

- `operations: ['execute']` — satu operasi generik untuk semua tool, sehingga token hasil approval satu tool terlihat sah untuk operasi tool lain.
- `roots: [workspace]` — binding akar menyeluruh: token berlaku untuk file mana pun di dalam workspace, bukan hanya file yang disetujui.
- `domains` tidak pernah divalidasi terhadap args aktual `http_request`/`web_fetch`.
- Batas ukuran payload hanya dihitung dari fingerprint args (yang sudah di-cap 100 KiB), sehingga konten `write_file` besar bisa lolos melebihi apa yang benar-benar dilihat user saat menyetujui.

Artinya: user menyetujui "tulis `docs/a.md`", tetapi token yang diterbitkan secara teknis mengizinkan tulis file mana pun di workspace. Celah itu ditutup dengan token yang hanya berlaku untuk sumber daya persis yang disetujui.

## Desain

Semua logika pengikatan dikurung di `packages/tiko_runtime/lib/src/capability.dart` sebagai API statis `CapabilityToken`:

- `operationForTool(tool)` — peta tool ke operasi sempit: `shell` → `exec`, `write_file` → `write`, `patch_file` → `patch`, `http_request`/`web_fetch` → `fetch`, tool lain → `execute`.
- `boundRoots(tool, args, {required workspaceRoot})` — untuk `write_file`/`patch_file` mengembalikan path file absolut persis dari args (hasil `p.normalize`; path absolut dipertahankan apa adanya); untuk tool lain tetap `[workspaceRoot]`. Hasil `List.unmodifiable`.
- `boundDomains(tool, args)` — host lowercase persis dari args `url` untuk `http_request`/`web_fetch`; URL tanpa host → list kosong (gagal ditolak di gate domain allowlist seperti biasa).
- `mint` kini menerima `maxBytes` opsional (default 100 KiB) yang ikut tersimpan di token.

Di `tiko_runtime.dart`, dua titik berubah:

1. **Penerbitan** (callback `confirm` saat approval): token dimint dengan `operations`, `roots`, dan `domains` yang dihitung dari `call` aktual, bukan lagi generik.
2. **Validasi** (`validateCapability` di `buildGate`): operasi harus cocok persis (fallback `execute` tetap diterima demi token lama), setiap root call harus berada di dalam root token (`p.isWithin` atau sama persis), setiap host call harus termuat di `domains` token, dan payload aktual (`content`/`new`/`body`) tidak boleh melebihi `maxBytes` (`_withinApprovedBytes`, dihitung via `utf8.encode`).

## Matriks test

Test baru `packages/tiko_runtime/test/capability_binding_test.dart` (6 test):

| Test | Yang diverifikasi |
| --- | --- |
| mapping operasi | `operationForTool` mengembalikan operasi sempit per tool |
| boundRoots file absolut | `write_file` mengikat path file persis, bukan seluruh workspace |
| boundRoots tool lain | tanpa path file → tetap `[workspaceRoot]` |
| boundDomains host persis | host lowercase persis dari `url` |
| boundDomains URL invalid | mengembalikan list kosong |
| token http tidak bisa write | token `http_request` ditolak untuk operasi `write` |

Ekspektasi path memakai POSIX (`/ws/docs/a.md`) — CI berjalan di Ubuntu sehingga aman.

## Kompatibilitas token lama

Token bergaya lama (operasi `execute`, root workspace penuh) tetap sah sampai kedaluwarsa normal — gate menerima `execute` sebagai fallback dan binding root workspace memuat semua file di dalamnya. Tidak ada migrasi ledger capability; token bersifat sekali pakai dan berumur pendek.

## Keterbatasan

- Binding root bersifat path-persis; tidak ada dukungan glob.
- `maxBytes` berlaku untuk kunci payload `content`/`new`/`body`; tool dengan payload di kunci lain mengandalkan fingerprint args (cap 100 KiB) seperti sebelumnya.

## Status

Selesai; menunggu konfirmasi CI hijau di HEAD setelah commit docs ini.
