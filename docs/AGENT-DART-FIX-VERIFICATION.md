# Agent Dart — Fix & Verification

## Perbaikan utama

- Menetapkan Dart workspace dan dependency test untuk package/app server.
- Memperbaiki kontrak core (`PermissionResult`, `RouteDecision`, `ToolExecutor`, `Message`).
- Memperbaiki provider Ollama native, MCP stdio adapter, registry JSON Schema, parser kalkulator, redactor, permission gate, dan isolate pool.
- Melengkapi Telegram STT download serta Discord interaction/slash-command handler.
- Menambahkan `afterTurn` pada in-memory store dan migrasi tabel operasional SQLite.
- Meneruskan `workspacePath` konfigurasi ke `AgentLoop` dan tool context.
- Menambahkan scaffold web Flutter, smoke widget test, cleanup timer, dan API switch terbaru.

## Verifikasi lokal

- `dart analyze --fatal-infos`: PASS — no issues found.
- Package tests: PASS — 7 package suites, 63 tests.
- AOT compile CLI dan daemon: PASS.
- CLI binary `/quit` smoke test: PASS.
- Daemon startup smoke test: PASS.
- `flutter test --no-pub`: PASS — 1 widget test.
- `flutter build web --release --no-wasm-dry-run`: artifact `build/web` berhasil dibuat dan berisi `index.html`, `flutter.js`, dan `flutter_bootstrap.js`.

## Catatan host

- SQLite native fallback aktif karena host tidak menyediakan `libsqlite3.so`; daemon menggunakan persistent JSON fallback sesuai desain.
- Flutter CLI analyzer pada host ARM64 berhenti setelah header dan menunggu di language-server; validasi compile/runtime Flutter tetap berhasil melalui widget test dan web release artifact.


## Catatan status P0 — 6 November 2026

Daftar verifikasi di atas berasal dari pekerjaan sebelumnya dan **tidak direproduksi** pada lingkungan patch ini. Pada lingkungan patch, Dart SDK dan Flutter SDK tidak tersedia. Karena itu, klaim PASS sebelumnya tidak boleh dianggap sebagai hasil verifikasi ulang terhadap revisi P0 terbaru.

Perbaikan P0 lanjutan pada revisi ini meliputi:
- Kontrak `TikoRuntime.chat(confirm:)` diselaraskan pada pemanggil CLI.
- `tiko setup` menghasilkan schema YAML kanonis yang dibaca parser runtime, dengan validasi provider, scalar, port, dan workspace.
- Approval dipusatkan pada `ApprovalBroker`; REST, WebSocket, Flutter, Telegram, dan CLI memutuskan ID yang sama. CLI berkomunikasi ke daemon, tidak membuat ledger in-memory tandingan.
- Approval tertunda hanya diexpire saat daemon baru berhasil memperoleh instance lock.
- `doctor` tetap menjalankan pemeriksaan host saat config rusak; CLI menggunakan lock daemon aktif untuk membedakan port milik sendiri.
- CI menjalankan analyze/test untuk workspace, smoke CLI/config/daemon, compile executable, serta Flutter analyze/test/web build tanpa `|| true` pada gate utama.
- Runtime normal menolak konfigurasi fatal; `doctor` dan perintah `config` tetap dapat dipakai untuk perbaikan.
- Token API disimpan pada `data/api.token` dengan permission POSIX `0600`, dan tidak dicetak ke log daemon.
- Flutter tidak mengirim ulang prompt secara otomatis melalui HTTP ketika WebSocket gagal, untuk menghindari efek samping ganda.

Pemeriksaan yang dilakukan pada revisi ini: YAML parsing dengan PyYAML untuk workflow/config dan template schema, `bash -n` untuk semua skrip shell, serta grep untuk referensi parameter lama/default token dan suppression gate. Semua pemeriksaan statis tersebut lulus. `dart pub get`, `dart analyze`, `dart test`, `flutter analyze`, `flutter test`, AOT compile, dan daemon smoke test **belum dijalankan** karena SDK tidak tersedia.
