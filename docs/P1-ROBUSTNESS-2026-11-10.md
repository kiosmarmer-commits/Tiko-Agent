# P1 Robustness Patch — 10 November 2026

## Basis dan batas status

- Baseline GitHub `main` terakhir diverifikasi: `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`.
- GitHub Actions run `42687414796` sukses untuk baseline itu (Dart + Flutter jobs), tetapi tidak menguji delta lokal yang dijelaskan pada status terbaru.
- Bundle implementasi pada ZIP menambahkan perubahan di atas baseline tersebut; belum dipush karena operasi GitHub branch ditolak HTTP 403.
- Dart/Flutter SDK tidak tersedia di lingkungan penyusunan; seluruh regression tests baru belum dieksekusi.
- Catatan bagian awal di bawah merangkum hardening yang sudah ada di baseline/bundle 9–10 November; bagian **Follow-up implementasi provider, SMTP, dan MCP** mencatat delta yang paling baru.

## Ringkasan

Patch ini melanjutkan backlog robustness dari laporan analisis Tiko-Agent. Temuan laporan tidak diterapkan mentah-mentah: kode baseline sudah mempunyai namespace MCP dan collision check terhadap nama registry. Namun, pemeriksaan baseline belum mencegah duplikasi nama di dalam satu batch registrasi, sementara `registerAll()` dapat meninggalkan partial registration bila item terakhir gagal.

## Perubahan source

### P1-R1 — Parallel execution explicit opt-in

- Menambahkan `ToolSpec.parallelSafe`, default `false`.
- `ParallelToolRunner` hanya menjalankan batch berurutan yang ditandai safe; satu tool yang tidak safe menjadi barrier dan diselesaikan terlebih dahulu.
- Hasil dikembalikan dalam urutan panggilan model.
- Exception dari executor diubah menjadi `ToolResult(isError: true)` untuk satu panggilan, sehingga tidak membatalkan hasil panggilan lain.
- Runtime mengambil nilai dari `registry.get(name)?.spec.parallelSafe`; custom/unknown tool default serial.
- Opt-in awal hanya diberikan kepada `datetime`, `calc`, `list_dir`, `read_file`, dan `grep`. `web_search` sengaja tetap serial karena melakukan network fetch dan mengubah cache proses; MCP/script/browser/shell/write/patch juga tetap serial.

### P1-R2 — Taint policy dipisah dari untrusted envelope

- Menambahkan `ToolTrust` sebagai klasifikasi bersama di `agent_core`.
- Output workspace `read_file`, `list_dir`, `grep`, `probe`, dan `shell` tetap dibungkus envelope `untrusted_data`, diredaksi dan dinetralisasi.
- Session taint untuk konfirmasi tambahan hanya dipicu oleh sumber eksternal: `web_fetch`, `web_search`, `http_request`, `cdp_browser`, `mcp_*`, dan `script_*`.
- Dengan demikian, membaca file lokal tidak memaksa setiap tool medium berikutnya meminta konfirmasi ekstra. Permission/risk normal tool tidak berubah.

### P1-R3 — MCP batch registration atomic

- `ToolRegistry.registerAll()` melakukan preflight sebelum memutasi map registry.
- Nama blank/tidak-trimmed ditolak.
- Duplikasi di dalam batch maupun collision terhadap registry existing menolak keseluruhan batch tanpa registrasi parsial.
- `McpToolLoader` mendeteksi duplikasi effective name setelah prefix `mcp_<serverId>_` dan menolak server tersebut dengan status yang jelas.
- Prefix namespace yang sudah ada tetap dipertahankan; tidak dibuat ulang dan tidak ditambahkan priority policy yang menyembunyikan tool.

### P1-R4 — SMTP STARTTLS, transport, dan header hardening

- Menghapus callback `onBadCertificate` yang sebelumnya menerima semua sertifikat; `SecureSocket.secure(socket, host: host)` memakai verifikasi CA dan hostname bawaan Dart.
- Saat STARTTLS diminta, server harus mengiklankan STARTTLS; tidak ada fallback plaintext. AUTH LOGIN hanya berjalan ketika username/password dipasangkan dan STARTTLS aktif.
- Greeting, EHLO, STARTTLS, AUTH, MAIL FROM, RCPT TO, DATA, dan respons setelah body diperiksa terhadap kode SMTP yang diharapkan; multiline response dibatasi maksimal 100 baris.
- Sender/recipient mailbox dan subject divalidasi untuk memblokir CR/LF/control-character injection. Body dinormalisasi ke CRLF dan dot-stuffing menggunakan callback replacement yang benar.
- Fake SMTP regression tests ditambahkan; live certificate/relay integration belum dijalankan.

### P1-R5 — Flutter admin API error transparency

- Endpoint admin GET (`capabilities`, `doctor`, `sessions`, `approvals`, `events`) sekarang memakai `_throwIf` konsisten dengan endpoint status/memory.
- HTTP 401/403/5xx tidak lagi disamarkan sebagai koleksi kosong; `refreshAdmin` menampilkan `adminError`.
- Query token WebSocket memakai `Uri.queryParameters`; ID delete memory memakai `Uri.encodeComponent` pada baseline bundle sebelumnya. Lifecycle test perangkat/reconnect tetap terbuka.

## Follow-up implementasi provider, SMTP, dan MCP — 10 November 2026

### P1-R6 — Provider routing fail-closed dan fallback probe reservation

- `Router.nextFallback()` tidak lagi hanya membaca `selectable`; ia mengambil slot dengan `ProviderHealth.tryAcquire()` untuk provider fallback, termasuk half-open. Hanya satu request yang dapat menguji provider half-open pada primary maupun fallback.
- `_pickPrimary()` tidak lagi mengembalikan provider yang masih open sebagai “last resort”. Kondisi seluruh provider open melempar `NoHealthyProviderException` dan AgentLoop mengembalikan pesan availability yang aman.
- Reservation dilepas pada jalur explain, guardrail, context build gagal, serta stop/budget sebelum provider dipanggil. Provider failure/success menutup slot melalui `recordFailure/recordSuccess`.
- `AgentLoop._safeCollect` kini menerima callback pembuka stream agar exception sinkron dari `chat()` juga melewati jalur fallback.
- Health state aktif runtime adalah `Router.ProviderHealth`. Class `CircuitBreaker`/`BreakerLlmProvider` di `agent_providers` dipertahankan untuk kompatibilitas tetapi bukan lapisan kedua pada composition root.

### P1-R7 — SMTP per-response timeout dan transaction deadline

- `EmailGateway` menambahkan `responseTimeout` (default 10 detik) dan `transactionTimeout` (default 60 detik setelah TCP connect).
- Greeting, setiap baris multiline response, socket flush dan STARTTLS handshake dibatasi deadline. Stopwatch monotonic mencegah perubahan jam sistem menggeser batas waktu.
- Timeout memicu cancel iterator dan `socket.destroy()` sehingga relay yang menerima koneksi tetapi berhenti membalas tidak menggantungkan pengiriman.
- Fake SMTP tests menahan greeting dan respons `MAIL FROM` untuk membuktikan batas per-response, bukan hanya timeout connect.

### P1-R8 — MCP Streamable HTTP GET SSE dan protokol versi

- `HttpMcpClient` membuka GET `text/event-stream` setelah initialize dan `notifications/initialized`; HTTP 404/405 berarti fitur GET tidak disediakan dan POST RPC tetap aktif. Kesalahan stream GET direkam dalam `transportErrors`, tidak mematikan jalur POST.
- Notifikasi server diekspos sebagai `serverEvents` dan disimpan di `notifications`. JSON-RPC server requests yang membawa ID disimpan di `serverRequests` untuk diagnostik, tetapi belum dijalankan/dijawab agent.
- Satu `http.Client` dipakai sepanjang hidup sesi GET SSE; stream dibatalkan sebelum DELETE dan client internal ditutup pada `close()`. Payload event SSE dibatasi 256 KiB default dan daftar diagnostik memakai ring sederhana maksimal 100 entri.
- `protocol_version` typed-config default `2025-11-25` bisa dioverride untuk server HTTP. Versi yang diterima dari initialize digunakan pada header `MCP-Protocol-Version` request berikutnya, GET, dan DELETE.
- Read-only JSON-RPC methods memiliki maksimal dua retry default (configurable per server melalui `max_read_retries: 0..3`) pada network exception/status 408, 425, 429, 502, 503, 504. `tools/call` dan notifications tidak di-retry karena potensi side effect duplikat.
- Endpoint URL menolak user-info, fragment, serta karakter whitespace/control. URL MCP tetap admin-trusted dan belum melewati SSRF guard; pembatasan akses konfigurasi/network harus dipertahankan.
- Tidak ada retry otomatis untuk `tools/call`, agar side effect tidak digandakan tanpa dukungan idempotency key. OAuth dynamic registration dan reconnect/resume masih backlog.

## Regression tests ditambahkan

- `packages/agent_core/test/parallel_tools_test.dart`
  - parallel safe grouping, serial barrier untuk tool unsafe, `parallel: false`, exception isolation, urutan result dan call ID.
- `packages/agent_core/test/tool_trust_test.dart`
  - external taint source, workspace untrusted envelope versus external taint, trusted output.
- `packages/agent_tools/test/registry_test.dart`
  - atomic registration saat collision intra-batch/registry, serta nama blank/untrimmed.
- `packages/agent_security/test/hardening_test.dart`
  - workspace file/list/grep/probe/shell output mendapatkan envelope; malformed envelope di-wrap ulang tanpa melempar exception.
- `apps/agent_flutter/test/agent_api_client_test.dart`
  - HTTP 401 pada seluruh admin GET tidak berubah menjadi data kosong.
- `packages/agent_core/test/router_health_test.dart` dan `router_fallback_test.dart`
  - all-provider-open fail-closed, release slot saat explain, fallback half-open single-probe reservation.
- `packages/agent_gateway/test/email_gateway_test.dart`
  - SMTP timeout pada greeting dan respons setelah `MAIL FROM`, di samping test STARTTLS downgrade, AUTH TLS, DATA/CRLF/dot-stuffing, dan input injection.
- `packages/agent_tools/test/mcp_http_lifecycle_test.dart`
  - GET SSE notification/server request, negotiated session/protocol header, malformed version, oversized event, GET stream error, retry read-only dan tidak retry `tools/call`.
- `packages/agent_tools/test/mcp_and_search_test.dart`
  - MCP loader menolak custom header dengan CR/LF/control characters.
- `packages/tiko_runtime/test/tiko_config_test.dart`
  - protocol version dan `max_read_retries` default/override/type/range; stdio tidak boleh menggunakan opsi HTTP; reserved protocol headers ditolak.

## Validasi yang tersedia saat paket dibuat

| Check | Hasil |
|---|---|
| Source archive unzip | PASS; arsip sumber pengguna dan bundle lengkap sebelumnya diperiksa |
| Python syntax checks untuk script project | PASS (`python3 -m compileall -q scripts tools/mock_mcp_server`) |
| Bash syntax checks | PASS (8/8 scripts) |
| YAML/JSON structure checks | PASS (24 YAML/YML; 3 JSON) |
| JavaScript syntax and Web UI tests | PASS (`node --check`; 3/3 tests via `scripts/web_ui_validate.sh`) |
| Static invariants | PASS (12/12 pemeriksaan source/kontrak patch) |
| Trailing whitespace | PASS (25 source/test/docs files diperiksa) |
| `dart format` | NOT RUN — Dart SDK tidak tersedia |
| `dart analyze --fatal-infos --fatal-warnings` | NOT RUN — Dart SDK tidak tersedia |
| `dart test` seluruh workspace | NOT RUN — Dart SDK tidak tersedia |
| `flutter analyze/test/build web` | NOT RUN — Flutter SDK tidak tersedia |
| Android/Termux dan gateway/MCP nyata | NOT RUN |

## Langkah verifikasi wajib

Dari root repository pada mesin yang memiliki versi toolchain project (baseline CI: Dart 3.13.4 dan Flutter 3.47.5):

```bash
dart pub get
dart format packages/agent_core/lib/src/models.dart \
  packages/agent_core/lib/src/parallel_tools.dart \
  packages/agent_core/lib/src/agent_loop.dart \
  packages/agent_core/test/parallel_tools_test.dart \
  packages/agent_core/test/tool_trust_test.dart \
  packages/agent_tools/lib/src/registry.dart \
  packages/agent_tools/lib/src/mcp/registry_mcp.dart \
  packages/agent_tools/test/registry_test.dart \
  packages/agent_security/lib/src/sanitizer.dart \
  packages/agent_security/test/hardening_test.dart \
  packages/agent_tools/lib/src/builtin.dart \
  packages/agent_tools/lib/src/grep.dart \
  packages/agent_tools/lib/src/web_search.dart \
  packages/tiko_runtime/lib/src/tiko_runtime.dart \
  packages/agent_gateway/lib/src/email_gateway.dart \
  packages/agent_gateway/test/email_gateway_test.dart \
  packages/agent_tools/lib/src/mcp/http_client.dart \
  packages/agent_tools/lib/src/mcp/registry_mcp.dart \
  packages/agent_tools/test/mcp_http_lifecycle_test.dart \
  packages/tiko_runtime/lib/src/tiko_config.dart \
  packages/tiko_runtime/lib/src/tiko_runtime.dart \
  packages/tiko_runtime/test/tiko_config_test.dart \
  apps/agent_flutter/lib/agent_api_client.dart \
  apps/agent_flutter/test/agent_api_client_test.dart
bash scripts/validate.sh
bash scripts/flutter_validate.sh
```

Jangan menandai patch sebagai release-ready sebelum seluruh gate tersebut lulus. Jika gagal, perbaiki kegagalan pertama yang benar-benar relevan dan jalankan ulang pipeline tanpa `|| true`.
