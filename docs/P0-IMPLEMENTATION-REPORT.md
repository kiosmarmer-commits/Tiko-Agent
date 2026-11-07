# Laporan Implementasi Perbaikan P0 — Tiko / Agent Dart

- **Tanggal:** 6 November 2026
- **Basis:** `agent_dart_tiko_complete.zip` dan hasil audit P0 sebelumnya
- **Cakupan:** TKO-P0-01 sampai TKO-P0-04, beserta hardening yang diperlukan agar jalur tersebut konsisten
- **Status kode:** patch diterapkan pada source tree
- **Status verifikasi:** pemeriksaan sintaks statis non-Dart lulus; kompilasi dan tes Dart/Flutter belum dapat dijalankan karena SDK tidak tersedia di lingkungan pengerjaan

> Catatan: file PRD mandiri `10-PRD-PASITIKO-TIKO.md` tidak terdapat pada berkas sumber yang tersedia. Implementasi ini mengacu pada AGD-00..09, konfigurasi, source code, dan empat item P0 pada laporan audit. Ini bukan klaim bahwa seluruh PRD telah diaudit ulang.

## 1. Ringkasan hasil

Keempat temuan P0 telah ditangani pada source code:

| ID | Masalah | Perbaikan yang diterapkan | Bukti/tes yang ditambahkan |
|---|---|---|---|
| TKO-P0-01 | CLI mengirim named argument `onConfirm`, sedangkan `TikoRuntime.chat()` menerima `confirm` | Pemanggilan CLI diselaraskan dengan API runtime. Konfirmasi CLI berjalan lewat callback `confirm` dan approval broker yang sama | Analisis statis nama parameter; jalur chat tetap masuk CI test dan smoke |
| TKO-P0-02 | `tiko setup` menghasilkan YAML yang tidak dibaca dengan benar oleh parser; provider dapat jatuh ke mock dan pengaturan lain tidak terbaca | `TikoConfig.setupYaml()` menjadi satu sumber template; template divalidasi sebelum tulis, disimpan lewat `ConfigStore`, dibaca ulang, lalu diverifikasi provider aktifnya. Parser memakai YAML parser riil dan validasi tipe | `tiko_config_test.dart`: mock, Ollama, workspace berkarakter khusus, provider invalid, tipe scalar salah, API port, agent budget, URL provider |
| TKO-P0-03 | Approval Flutter/API tidak menyelesaikan waiter AgentLoop yang sama; alur callback dapat meminta persetujuan ganda | Satu `ApprovalBroker` menjadi sumber data persetujuan. AgentLoop membuat request, menunggu broker; Telegram/CLI menjadi notifier ke broker; REST, WebSocket, dan Flutter memutuskan ID request yang sama. Hilangkan callback gate duplikat | `approval_broker_test.dart`, `http_api_approval_test.dart`, `approval_api_integration_test.dart`, `chat_controller_test.dart` |
| TKO-P0-04 | Doctor menghentikan pemeriksaan host ketika konfigurasi tidak valid dan menghasilkan pemeriksaan RAM yang tidak konsisten | Diagnosis konfigurasi dipisah dari pemeriksaan host; RAM, disk, Termux, SQLite, network, queue, workspace, data-dir, memory, sandbox, daemon/port, provider tetap diperiksa | `runtime_doctor_test.dart`; doctor CLI dan endpoint `/v1/doctor` memakai runtime yang sama |

## 2. Rincian implementasi

### 2.1 CLI dan kontrak runtime

- Menyamakan nama parameter konfirmasi menjadi `confirm` pada pemanggilan runtime.
- Perintah `approve`, `deny`, dan `approvals` tidak lagi membuat runtime/ledger terpisah untuk memutus approval daemon. Perintah tersebut membaca token lokal dan mengirim keputusan melalui API daemon aktif.
- Bila daemon tidak hidup, token tidak ada, config invalid, atau approval sudah tidak pending, CLI mengembalikan kegagalan yang jelas dan non-zero exit code.
- CI memasukkan smoke deterministic command dan chat mock.

Berkas utama:
- `apps/tiko/bin/tiko.dart`
- `packages/tiko_runtime/lib/src/tiko_runtime.dart`
- `packages/tiko_runtime/lib/src/remote_client.dart`

### 2.2 Konfigurasi dan `tiko setup`

- Template onboarding dibuat di `TikoConfig.setupYaml()` dan menggunakan struktur yang sama dengan parser `TikoConfig.parse()`.
- Provider yang diterima setup dibatasi ke `mock` dan `ollama`/`ollama_native`, sesuai provider yang tersedia di factory.
- `setup` menolak opsi provider yang tidak dikenal, tidak menimpa file invalid tanpa `--force`, memvalidasi template sebelum tulis, menyimpan revisi, membaca kembali file dari disk, dan memeriksa bahwa default provider benar-benar terdaftar serta aktif.
- Parser YAML menggunakan `package:yaml`, menolak duplicate key, dan melakukan validasi jenis nilai untuk mapping, URL provider, secret reference, allowlist, API port, serta batas resource agent.
- Secret mentah di YAML ditolak; provider API key harus berupa `env:NAMA_VAR`.
- Runtime normal gagal tertutup pada fatal config issue. `doctor` dan perintah config tetap dapat dijalankan dengan `allowInvalidConfig` agar pengguna bisa memperbaiki file.

Berkas utama:
- `packages/tiko_runtime/lib/src/tiko_config.dart`
- `packages/tiko_runtime/lib/src/config_store.dart`
- `packages/tiko_runtime/lib/src/provider_factory.dart`
- `apps/tiko/bin/tiko.dart`
- `config/agent.yaml`

### 2.3 Approval end-to-end

Satu alur yang diterapkan:

1. AgentLoop meminta izin melalui callback runtime.
2. Runtime membuat `ApprovalRequest` dengan ID, sesi, channel, tool, risk, fingerprint argumen, waktu pembuatan, dan expiry.
3. Broker menyimpan status `pending` secara persisten.
4. Event `approval.pending` dikirim ke event bus; server meneruskannya ke WebSocket/Flutter.
5. Telegram/CLI dapat menampilkan prompt, tetapi tidak memiliki ledger atau waiter sendiri.
6. Flutter, REST, WebSocket, CLI, atau Telegram mengirim keputusan dengan ID yang sama.
7. Broker hanya menerima keputusan bila request masih pending dan belum kedaluwarsa. Keputusan replay ditolak.
8. Setelah approve, runtime menerbitkan capability sekali pakai yang terikat pada session dan nama tool; AgentLoop memvalidasi capability pada pemeriksaan kedua, menghapus ID capability sebelum argumen mencapai adapter tool, lalu mengeksekusi tool.

Perlindungan tambahan:
- Membaca ledger oleh proses CLI tidak lagi menandai semua approval pending sebagai kedaluwarsa.
- Approval pending lama hanya dibersihkan ketika daemon baru telah memperoleh instance lock dan memulai startup.
- Expiry, penolakan, keputusan ganda, keputusan terlambat, keputusan sebelum waiter mulai, dan kegagalan persistensi ditangani fail-closed.
- Flutter tidak mengulang prompt lewat HTTP setelah WebSocket error, karena server mungkin sudah menerima task dan mulai menjalankan side effect.
- Kegagalan jaringan ketika mengirim keputusan tidak menghilangkan prompt dari controller sehingga pengguna dapat mencoba lagi.
- Halaman Approvals Flutter menampilkan kesalahan ketika keputusan gagal/kedaluwarsa, bukan mengabaikannya.

Berkas utama:
- `packages/tiko_runtime/lib/src/approval_ledger.dart`
- `packages/tiko_runtime/lib/src/tiko_runtime.dart`
- `packages/agent_core/lib/src/agent_loop.dart`
- `packages/agent_gateway/lib/src/http_api.dart`
- `apps/agentd/bin/agentd.dart`
- `apps/agent_flutter/lib/agent_api_client.dart`
- `apps/agent_flutter/lib/ui/chat_controller.dart`
- `apps/agent_flutter/lib/main.dart`
- `apps/tiko/bin/tiko.dart`

Endpoint yang digunakan:
- `GET /v1/approvals`
- `POST /v1/approvals/{id}` dengan body `{"approve": true|false}`
- `POST /v1/confirm` untuk kompatibilitas endpoint lama
- WebSocket `/v1/stream` mengirim event `confirm` dan event keputusan

### 2.4 Doctor dan diagnosis

Doctor tidak lagi menempatkan seluruh pemeriksaan host di dalam cabang `config valid`. Setiap kategori diagnosis ditampilkan terpisah sehingga config invalid tidak menyembunyikan informasi yang dibutuhkan untuk memperbaikinya.

Pemeriksaan yang tersedia dalam hasil doctor:
- validitas konfigurasi dan lokasi field bermasalah;
- profil resource, RAM tersedia, disk bebas;
- deteksi Termux dan keberadaan library SQLite native;
- indikasi konektivitas jaringan dan jumlah offline queue;
- keberadaan workspace dan kemampuan tulis pada data directory;
- backend memory dan jenis sandbox;
- informasi daemon aktif serta konflik port;
- provider terdaftar, enabled/disabled, status probe, dan detail kegagalan koneksi.

Pemeriksaan probe provider tetap bersifat eksplisit (`doctor --probe`) sehingga doctor biasa tidak harus membuat koneksi jaringan.

Berkas utama:
- `packages/tiko_runtime/lib/src/tiko_runtime.dart`
- `packages/tiko_runtime/lib/src/resource_monitor.dart`
- `apps/tiko/bin/tiko.dart`
- `apps/agentd/bin/agentd.dart`

## 3. Hardening tambahan yang terkait erat dengan P0

### 3.1 Token API

- Menghapus fallback `dev-token`.
- Token otomatis dibuat dengan `Random.secure()` dan sekurang-kurangnya 128-bit; token yang dibuat oleh `DaemonManager` menggunakan 256-bit.
- Token disimpan pada `data/api.token`, bukan di YAML atau log.
- Pada POSIX, file token dibatasi ke permission `0600`; file symlink ditolak saat dibaca; ukuran file dibatasi.
- Daemon tidak memulai layanan bila token tidak dapat disimpan secara aman.
- Dokumentasi dan UI menyatakan token disimpan lokal, bukan dicetak ke terminal.

Berkas utama:
- `packages/tiko_runtime/lib/src/api_token_store.dart`
- `packages/tiko_runtime/lib/src/daemon_manager.dart`
- `apps/agentd/bin/agentd.dart`

### 3.2 Lifecycle daemon dan lock

- `daemon start` menunggu dua bukti readiness: lock instance dan endpoint `/health`.
- Lock aktif tetapi API tidak sehat dilaporkan sebagai kondisi unhealthy, bukan sukses start.
- `daemon stop` meminta shutdown melalui endpoint API terautentikasi.
- CLI tidak lagi mengirim SIGTERM/SIGKILL langsung ke PID dalam lock file, karena PID dapat dipakai ulang oleh proses lain.
- Daemon menyelesaikan shutdown melalui signal internal, menutup scheduler, approval waiter, gateway, HTTP server, event stream, lalu melepas lock miliknya sendiri.
- `restart` tidak melanjutkan start baru bila stop gagal.
- `RuntimeLock.release()` hanya menghapus lock yang PID-nya cocok dengan proses pemilik sekarang; lock corrupt tidak dihapus otomatis.

Berkas utama:
- `packages/tiko_runtime/lib/src/daemon_manager.dart`
- `packages/tiko_runtime/lib/src/runtime_lock.dart`
- `packages/tiko_runtime/lib/src/remote_client.dart`
- `packages/agent_gateway/lib/src/http_api.dart`
- `apps/agentd/bin/agentd.dart`
- `scripts/smoke_agentd.sh`

### 3.3 Safe mode dan approval capability

- Safe mode tetap mengizinkan daftar tool read-only/deterministik yang ditentukan.
- Tool di luar daftar tersebut tidak auto-run: jalurnya menjadi approval eksplisit lalu capability sekali pakai.
- Mode panic tetap menolak tool berdampak tinggi tertentu.
- Risiko tool berasal dari `ToolSpec.risk` dan tabel nama, menggunakan risiko yang lebih ketat. Tool tak dikenal fail-closed.

Berkas utama:
- `packages/agent_security/lib/src/kill_switch.dart`
- `packages/agent_security/lib/src/capability_gate.dart`
- `packages/agent_security/lib/src/permission_gate.dart`

### 3.4 CI dan release validation

- SDK Dart CI diselaraskan ke Dart 3.13.4 dan Flutter tetap 3.47.5.
- Job Dart menjalankan dependency resolution, analisis seluruh package/app, test seluruh package/app, kalkulator deterministik, chat mock, setup provider mock/Ollama, config validation, compile entrypoint AOT, dan daemon HTTP lifecycle smoke.
- Job Flutter menjalankan `pub get`, `flutter analyze`, widget tests, dan web release build.
- Menghapus bypass `continue-on-error` dan `|| true` dari release gate utama.
- `scripts/validate.sh` menjadi pipeline lokal yang sama ketatnya.

Berkas utama:
- `.github/workflows/ci.yml`
- `scripts/validate.sh`
- `scripts/ci_test.sh`
- `scripts/smoke_agentd.sh`
- `.gitignore`

## 4. Test baru/diubah

- `packages/tiko_runtime/test/approval_broker_test.dart`
- `packages/tiko_runtime/test/runtime_doctor_test.dart`
- `packages/tiko_runtime/test/runtime_lock_test.dart`
- `packages/tiko_runtime/test/tiko_config_test.dart`
- `packages/agent_gateway/test/http_api_approval_test.dart`
- `packages/agent_security/test/permission_gate_test.dart`
- `apps/agentd/test/approval_api_integration_test.dart`
- `apps/agent_flutter/test/chat_controller_test.dart`

Test tersebut mencakup kontrak config, setup provider mock/Ollama, validasi tipe, approval lifecycle dan replay, shared broker lintas API, event approval WebSocket, lock, penghentian daemon melalui API terautentikasi, safe-mode gate, dan perilaku controller Flutter.

## 5. Hasil verifikasi yang benar-benar dilakukan

<details>

| Pemeriksaan | Hasil |
|---|---|
| `bash -n` seluruh `scripts/*.sh` | **PASS** |
| `node --check apps/agentd/web/app.js` | **PASS** |
| Parsing YAML workflow, config, root pubspec/lock, seluruh package pubspec, dan Flutter pubspec (15 file) | **PASS** |
| Tidak ditemukan lagi pemanggilan `onConfirm:` yang usang | **PASS** |
| Tidak ditemukan `dev-token`, `pendingConfirms`, atau pesan token dicetak saat startup | **PASS** |
| Tidak ada `continue-on-error` / `|| true` pada workflow CI dan `scripts/validate.sh` | **PASS** |
| Dart SDK tersedia | **NO — tidak tersedia** |
| Flutter SDK tersedia | **NO — tidak tersedia** |
| `dart pub get` | **NOT RUN** |
| `dart analyze` / `dart test` | **NOT RUN** |
| `flutter analyze` / `flutter test` / web build | **NOT RUN** |
| AOT compile / daemon live smoke | **NOT RUN** |

</details>

**Penting:** PASS di atas hanya menunjukkan pemeriksaan statis non-Dart. Saya belum dapat membuktikan bahwa perubahan Dart bebas compile error atau tes runtime lulus. Karena itu patch ini tidak diberi label “build verified”.

## 6. Verifikasi wajib setelah dipindahkan ke lingkungan Dart/Flutter

Dari root proyek:

```bash
dart --version
flutter --version
dart pub get
bash scripts/validate.sh
```

Kemudian verifikasi Flutter secara terpisah:

```bash
cd apps/agent_flutter
flutter pub get
flutter analyze
flutter test --reporter expanded
flutter build web --release
```

Jika `dart analyze` atau test gagal, selesaikan error pertama yang relevan lalu ulangi seluruh pipeline. Jangan menggunakan `|| true` untuk melewati kegagalan.

## 7. Batas cakupan dan pekerjaan berikutnya

P0 ini tidak berarti Tiko sudah setara penuh dengan Hermes atau semua komponen agent sudah terintegrasi. Pekerjaan yang masih berada di luar patch P0 antara lain:

- mengintegrasikan scheduler, MCP registry, script runner, skills, dan subagent sepenuhnya ke komposisi `TikoRuntime`;
- menyambungkan retrieval memory ke ContextBuilder dan menambahkan provenance per fakta/segmen konteks;
- melakukan sandboxing OS yang kuat untuk script, MCP, dan tool shell;
- membatasi capability berdasarkan operasi/path/domain/resource secara menyeluruh di adapter tool (gate saat ini memverifikasi expiry, single-use, session, dan nama tool);
- menambahkan approval ledger multi-proses dengan file lock/SQLite transaction bila CLI chat dan daemon boleh menulis ledger bersamaan;
- memperluas evaluasi skill dengan golden task yang menjalankan tool nyata pada sandbox terisolasi;
- menguji backup, migrasi, crash-recovery, dan permission pada Android/Termux serta Linux/VPS.

Paket ini sebaiknya dianggap **P0 source patch siap untuk verifikasi SDK**, bukan release final sebelum perintah di bagian 6 lulus.
