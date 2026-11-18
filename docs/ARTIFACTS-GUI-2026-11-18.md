# GUI-P2-04: Artifacts & diff viewer — 2026-11-18

Item **GUI-P2-04** (Artifacts & diff viewer, gap "Hasil agent dapat
direview; Download/preview only through safe APIs"): admin kini dapat
**menjelajah hasil kerja agent di workspace secara read-only** — daftar
file, pratinjau konten, dan **diff terhadap backup `.bak`** yang
ditulis otomatis oleh tool `write_file` — di atas endpoint yang
benar-benar ada (`GET /v1/artifacts*`). Semua akses path fail-closed
melalui `PathSafety.resolveInRoot` (symlink-aware, anti escape root).

## 1. Runtime (`packages/tiko_runtime`)

- `TikoRuntime.artifactsList({sub, limit = 200})`: walk rekursif
  workspace (skip dirs `.git`, `build`, `.dart_tool`, `node_modules`,
  `.vibe`, `__pycache__`), urut by basename; return
  `{files: [{path relatif, bytes, modified}], truncated}`; path invalid
  → `ArgumentError`.
- `TikoRuntime.artifactsRead(path, {maxBytes = 262144})`: baca konten
  via `PathSafety.resolveInRoot(workspace, path)`; deteksi biner
  (byte 0 dalam 8 KB pertama + heuristik >10% non-tekstual); return
  `{path, bytes, binary, truncated, content, bak_exists}`; file hilang
  → `StateError`.
- `TikoRuntime.artifactsDiff(path, {maxEntries = 400})`: diff baris
  **`.bak` (versi lama yang ditulis otomatis oleh `write_file`) vs
  file saat ini**; `.bak` hilang → `old_exists: false`; **LCS
  line-diff** sendiri (trim prefix/suffix
  identik, DP ≤1200 baris per sisi dengan fallback marker semua `+/-`,
  tail tanpa `=`), marker `=`/`-`/`+`, flag `truncated`; return
  `{path, old_exists, new_exists, lines: [{type, text}], truncated}`.

## 2. Gateway (`packages/agent_gateway`)

- Callback `artifactsListProvider(String dir)`,
  `artifactsReadProvider(String path)`, `artifactsDiffProvider(String
  path)` — null → `501 not_implemented`.
- Route `GET /v1/artifacts[?dir=]`, `GET /v1/artifacts/read?path=`,
  `GET /v1/artifacts/diff?path=` (auth bearer; method lain → 404).
- `_parseArtifactsPath`: wajib non-kosong untuk read/diff (400),
  maksimal 256 char, tolak `\u0000`/`\r`/`\n` → `400 invalid_request`
  (bukan 500).

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- 3 provider langsung ke `rt.artifactsList/Read/Diff`;
  `ArgumentError` → `400 invalid_request`, `StateError` → `404
  not_found`.

## 4. Flutter (`apps/agent_flutter`)

- DTO: `ArtifactFileInfo`, `ArtifactsListing`, `ArtifactContent`,
  `DiffLine`, `ArtifactDiff` (semua `fromMap` toleran).
- Klien: `listArtifacts(dir)`, `readArtifact(path)`,
  `diffArtifact(path)` (timeout 15s); repo abstract + impl
  `artifacts/artifactRead/artifactDiff`.
- `ui/artifact_view.dart` (`ArtifactsPage`, StatefulWidget): header
  (jumlah file + flag terpotong + dir aktif), tombol refresh, tombol
  `.. (naik)` saat dir non-kosong, daftar file (ikon + ukuran), tap
  file → pratinjau `_PreviewCard` (monospace, max-height 320, catatan
  terpotong) dengan **toggle Preview ↔ Diff** (hanya saat `bak_exists`;
  diff berwarna `+` hijau / `-` merah / `=` muted) dan tombol close;
  file biner tampil placeholder tanpa konten.
- Route `AppRoute.artifacts` (rail "Artifacts", ikon folder_copy,
  non-primary → kelompok More di mobile); lazy load saat pertama masuk
  route (bukan bagian refreshAdmin 17 GET); state
  `artifactsListing/artifactsDir/artifactContent/artifactDiff` di
  main.dart; More page memuat ListTile Artifacts.

## 5. Web parity (`apps/agentd/web`)

- Tab **Artifacts**: tombol refresh, daftar file (`textContent` aman,
  klik → pratinjau), tombol `.. (naik)` bila dir aktif non-kosong,
  panel pratinjau (judul, toggle satu tombol Preview↔Diff yang muncul
  saat diff ada, close), konten diff ikut berwarna via class span —
  tetap aman XSS karena semua teks lewat `textContent`. Test node
  harness +2 (23 total), termasuk asersi payload ber-`<script>` tidak
  pernah masuk `innerHTML`.

## 6. Dokumentasi & test

- Test: runtime 6 baru (`artifacts_test.dart` — listing+skip dirs,
  subdir + anti-escape, read teks/biner/missing, truncation, LCS
  markers + maxEntries), gateway 3 baru (`http_api_artifacts_test.dart`
  — happy path + path ter-encode, 400 tanpa path, 401/501/POST 404),
  Flutter 11 baru (5 repository + 6 view), web 2 baru.
- Verifikasi: `dart test` tiko_runtime 269, agent_gateway 180, agentd
  7 — semua lulus; `flutter analyze` bersih; `flutter test` 225 lulus;
  `flutter build web --release` sukses; `node --check` app.js + test
  harness; `node --test` 23 lulus.

## Yang TIDAK termasuk

- **Read-only penuh** — TIDAK ada download/upload/edit/hapus file dari
  GUI; write tetap eksklusif milik agent via tool `write_file` (GUI
  hanya membaca hasilnya).
- Listing dibatasi **200 file** dengan flag `truncated` (tanpa
  pagination/pencarian nama berikutnya).
- Konten terpotong **256 KB per read**; tidak ada pratinjau file
  biner (gambar/arsip) — hanya placeholder.
- Diff hanya **terhadap `.bak` langsung** (versi lama segera setelah
  tool `write_file` menimpa) — tidak ada riwayat multi-versi, tidak
  ada diff antar dua file arbitrer, dan `.bak` baru muncul setelah
  penimpaan pertama (file yang baru dibuat belum punya diff).
- Hanya workspace runtime yang terlihat; tidak ada browse filesystem
  di luar root (`PathSafety` fail-closed, termasuk anti-symlink).
