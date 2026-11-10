# 08 — Registri Dependensi dan Toolchain

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot manifest/lock/CI:** branch `main`, commit `69b6da421bf2a4682dce19e05d1ea608607250be`, 9 November 2026.

Dokumen ini sengaja memisahkan **constraint yang ditulis di pubspec.yaml**, **versi ter-resolve dalam pubspec.lock**, dan **versi terbaru yang tersedia di pub.dev**. Audit ini membaca dua file pertama; tidak menyatakan semua paket adalah rilis pub.dev paling baru.

## 1. Toolchain

| Komponen | Constraint / versi pada source |
|---|---|
| Root Dart SDK | `^3.8.0` |
| Dart CI | `3.13.4` (`dart-lang/setup-dart@v1`) |
| Flutter CI | `3.47.5` (`subosito/flutter-action@v2`) |
| Lint CI | `dart analyze --fatal-warnings` (INFO lints are advisory; warnings/errors block CI) pada workspace member |
| Flutter checks | `flutter analyze`, `flutter test`, `flutter build web --release` |

## 2. Dependency langsung per paket

Versi di bawah adalah constraint `pubspec.yaml`, bukan angka latest:

| Package | Dependency eksternal langsung |
|---|---|
| Root workspace | `lints ^5.0.0`, `test ^1.25.0` (dev) |
| `agent_core` | `meta ^1.16.0`, `collection ^1.19.0`, `uuid ^4.5.1`, `path ^1.9.0`, `yaml ^3.1.2` |
| `agent_calc` | `lints ^5.0.0`, `test ^1.25.0` (dev); engine core murni Dart |
| `agent_providers` | `http ^1.2.2`, `meta ^1.16.0` |
| `agent_tools` | `http ^1.2.2`, `path ^1.9.0` + internal `agent_calc`, `agent_core` |
| `agent_memory` | `meta ^1.16.0`, `uuid ^4.5.1`, `path ^1.9.0`, `sqlite3 ^2.4.6` + internal packages |
| `agent_scheduler` | `timezone ^0.10.0`, `uuid ^4.5.1` + `agent_core` |
| `agent_gateway` | `http ^1.2.2`, `path ^1.9.0`, `crypto ^3.0.0` + `agent_core` |
| `agent_security` | `path ^1.9.0` + `agent_core` |
| `tiko_runtime` | `path ^1.9.0`, `uuid ^4.5.1`, `yaml ^3.1.2` + internal packages |
| `apps/agentd` | Internal packages; tidak menambahkan SDK provider eksternal |
| `apps/agent_cli` | `args ^2.6.0` + internal packages |
| `apps/tiko` | `path ^1.9.0` + internal packages |
| `apps/agent_flutter` | Flutter SDK, `http ^1.2.2`, `web_socket_channel ^3.0.1` |

Manifest `agent_providers` menggunakan `http`; adapter OpenAI-compatible, Ollama native, Anthropic dan Gemini berada di source repo. Jangan menyebut `openai_dart`, `ollama_dart`, `anthropic_sdk_dart`, `googleai_dart`, atau Drift sebagai direct runtime dependencies saat snapshot ini.

## 3. Beberapa versi resolved dari pubspec.lock

Contoh paket yang ter-resolve pada lockfile snapshot:

| Package | Resolved |
|---|---:|
| `http` | 1.6.0 |
| `sqlite3` | 2.9.4 |
| `web_socket_channel` | 3.0.3 |
| `yaml` | 3.1.4 |
| `uuid` | 4.6.0 |
| `path` | 1.9.1 |
| `meta` | 1.19.0 |
| `collection` | 1.19.1 |
| `args` | 2.7.0 |
| `crypto` | 3.0.8 |
| `lints` | 5.1.1 |
| `test` | 1.33.0 |

Tidak semua package runtime disebut di tabel contoh ini. `pubspec.lock` pada branch adalah sumber lengkap resolusi; jalankan `dart pub get` sebelum mengubah dependency.

## 4. Dependency yang perlu dibersihkan dari dokumentasi lama

Pernyataan lama berikut tidak sesuai manifest aktual:

- `drift` sebagai ORM/ketergantungan storage — source menggunakan `sqlite3` dan raw SQL migration (`DriftStyleMigrations` hanya nama helper migrasi).
- SDK client `openai_dart`, `ollama_dart`, `anthropic_sdk_dart`, `googleai_dart` sebagai dependency package `agent_providers` — adapter saat ini menggunakan `http`.
- `sqlite-vec` sebagai vector backend default — runtime saat ini membangun `BruteForceVectorIndex`.
- Versi hasil pencarian 4 November sebagai klaim “versi terbaru” — tanggal/hasil tersebut tidak lagi menjadi verifikasi tanggal ini.

## 5. Cara verifikasi

```bash
dart --version
flutter --version
dart pub get
dart pub outdated
```

Untuk perubahan dependency:

1. Ubah `pubspec.yaml` pada package pemilik penggunaan.
2. Jalankan `dart pub get` agar `pubspec.lock` berubah secara sadar.
3. Periksa diff lockfile, license, minimum SDK dan transitive updates.
4. Jalankan strict analyze, test semua workspace, CLI/daemon smoke dan Flutter suite bila package Flutter/API berubah.
5. Catat package baru, alasan, source dan hasil verifikasi pada log dependency.

## 6. CI sebagai kontrak toolchain

Workflow `.github/workflows/ci.yml`:

- Dart 3.13.4: Bash/Python syntax validation, pub get, strict static analysis, tests semua workspace members, calculator/chat/setup/config smoke, executable compilation dan daemon lifecycle/API smoke.
- Flutter 3.47.5: `flutter pub get`, analyze, test, dan web release build.

Jangan menghapus gate atau menambahkan `|| true` untuk membuat job tampak hijau. Laporan keberhasilan CI berlaku hanya untuk SHA yang diperiksa.
