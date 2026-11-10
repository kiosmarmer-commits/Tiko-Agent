# Audit Repository dan Rekonsiliasi Dokumentasi — 9 November 2026

## 1. Identitas snapshot

| Item | Nilai |
|---|---|
| Repository | `kiosmarmer-commits/Tiko-Agent` |
| Branch | `main` |
| Commit | `69b6da421bf2a4682dce19e05d1ea608607250be` |
| Message | `bug fix gpt` |
| Timestamp | `2026-11-09T14:35:45Z` |
| Parent commit | Tidak ada (root commit) |
| Commit stats | 47.850 additions, 0 deletions |
| CI run | [42636270018](https://github.com/kiosmarmer-commits/Tiko-Agent/actions/runs/42636270018) — success |
| Tree inventory | 359 files; 102 file paths di folder `test/` |

Audit ini membaca tree GitHub, root/package `pubspec.yaml`, `pubspec.lock`, workflow CI dan source penting di runtime/core/provider/tool/memory/scheduler/gateway/Flutter/Web. Commit saat snapshot merupakan root commit tanpa parent dan seluruh repository masuk sebagai additions; ini berarti sejarah Git branch saat ini dimulai dari snapshot tersebut. Ini bukan full security audit atau test ulang seluruh source pada perangkat Android.

## 2. Temuan dokumentasi utama

| ID | Lokasi | Ketidakcocokan | Perbaikan dalam paket ini |
|---|---|---|---|
| DOC-01 | `README.md` | Status masih M0/M1, struktur paket tidak lengkap, roadmap fase ganda/kontradiktif, fitur implementasi baru tidak masuk | Ditulis ulang sebagai overview snapshot aktual + quick start |
| DOC-02 | `INSTALL.md` | Panduan lama hanya menginstal overlay UI repair berbasis commit lama, bukan instalasi aplikasi | Ditulis ulang untuk Linux/VPS/Termux/Web/Flutter |
| DOC-03 | `docs/00-INDEX.md` | Tanggal dependency 4 Nov dan status per 8 Nov sudah tertinggal | Indeks dan status snapshot diperbarui |
| DOC-04 | `docs/01-ARSITEKTUR.md` | Struktur lama tidak menyertakan `agent_calc`, `tiko_runtime`, `apps/tiko`; beberapa diagram berupa rencana | Diganti arsitektur runtime aktual, dibedakan dari pseudocode desain |
| DOC-05 | `docs/02-PROVIDER-AI.md` | SDK provider eksternal dianggap dependency, tier routing belum tercatat, fallback/health tidak akurat | Disesuaikan dengan `ProviderFactory`, Router, dan circuit breaker source |
| DOC-06 | `docs/03-TOOLS-MCP-SKILLS.md` | Streamable HTTP dan skill approval/golden evaluator ditulis seolah belum ada | MCP stdio/HTTP dan skill lifecycle aktual didokumentasikan |
| DOC-07 | `docs/04-MEMORI-DB-PENCARIAN.md` | Drift/SQLite-vec diposisikan sebagai backend aktif; session schema digabung dengan memory | Ditulis ulang berdasarkan sqlite3 raw SQL, migration v6, FTS5, JSON fallback, owner scope, FileSessionStore, RRF |
| DOC-08 | `docs/05-SCHEDULER-BOT-GATEWAY.md` | Tidak mencerminkan durable delivery ack/retry, IANA DST, dan gateway baru | Diperbarui dengan semantik dan env config dari daemon |
| DOC-09 | `docs/06-AGENT-ALGORITMA-SELFLEARNING.md` | Banyak algoritma implemented masih ditulis seperti backlog; self-learning bisa disalahartikan sebagai training | Dibedakan implementasi, opsi konfigurasi, rumus aktual dan batasan |
| DOC-10 | `docs/07-KEAMANAN-OBSERVABILITAS.md` | Tidak menguraikan capability per operasi/resource/path/domain dan ledger approval terbaru | Menambahkan resource-bound capability, approval, token, sandbox caveats |
| DOC-11 | `docs/08-REGISTRI-DEPENDENSI.md` + `dependency-log.md` | Versi 4 Nov dan SDK/Drift yang tidak ada di manifest dianggap direct dependencies | Diubah menjadi daftar dependency dari pubspec + contoh lock resolutions; tidak klaim latest pub.dev |
| DOC-12 | `docs/09-ROADMAP-TASKS.md` | Roadmap M0–M7 menyuruh mulai dari fondasi yang sudah ada | Diganti backlog gap yang masih terbukti dan release checklist |
| DOC-13 | `docs/STATUS-2026-11-08.md` | Dipakai sebagai current status walau HEAD sudah maju | Diberi label historical/archive dan ditautkan ke status baru |
| DOC-14 | `AUDIT-AND-FIX-REPORT.md` | Laporan overlay mengacu ke baseline UI lama; mudah disalahartikan sebagai audit UI saat ini | Diberi penanda arsip; temuan harus dirujuk ke source/CI snapshot baru |
| DOC-15 | `apps/agentd/web/README-UI-REPAIR.md` | Menyebut overlay replacement sebagai cara instalasi, walau UI kini sudah menjadi source app daemon | Diganti menjadi panduan Web UI yang ada di repo |
| DOC-16 | `apps/agent_flutter/README.md` | Petunjuk cukup ringkas dan tidak menerangkan dependency client/server | Diperbarui dengan peran client, token, base URL dan validasi |

## 3. Bukti implementasi yang menjadi dasar

### Runtime / core

- `packages/tiko_runtime/lib/src/tiko_runtime.dart`: `TikoRuntime.create`, runtime tool registry, memory backend selection, ledgers, subagent registration, `startMcp`, `startScheduler`, skill evaluate/approve/rollback.
- `packages/agent_core/lib/src/agent_loop.dart`: ReAct loop, budget, fallback chain, sequential permission, parallel tools, loop detector, memory persistence, optional reflection, skill synthesis.
- `packages/agent_core/lib/src/router.dart`: tier selection, heuristic/DecisionProvider, provider health score, fallback event trace.
- `packages/agent_core/lib/src/skill_gate.dart`, `skill_ledger.dart`, `skill_metrics.dart`, `skill_synthesis.dart`: skill score/synthesis, isolated promotion gate contract, approval and metrics ledgers.

### Provider

- `packages/tiko_runtime/lib/src/provider_factory.dart`: mock, OpenAI-compatible, Ollama native, Anthropic dan Gemini; optional System One DecisionProvider dan Ollama embedder.
- `packages/agent_providers/lib/src/circuit_breaker.dart`: threshold/open duration, half-open single probe, releaseProbe, distinct all-breakers-open error.
- `packages/tiko_runtime/lib/src/tiko_config.dart`: parsing/validation `providers.tiers`, `search.tavily_api_key`, MCP server types/secrets dan config fields lain.

### Tools, memory dan scheduler

- `packages/agent_tools/lib/src/builtin.dart`, `registry.dart`, `sandbox.dart`, `ssrf.dart`, `tool_forge.dart`, `web_search.dart`.
- `packages/agent_tools/lib/src/mcp/stdio_client.dart` dan `http_client.dart`.
- `packages/agent_memory/lib/src/sqlite_store.dart`, `persistent_store.dart`, `drift_schema.dart`, `file_session_store.dart`.
- `packages/agent_scheduler/lib/src/scheduler.dart` serta `timezones.dart`/`cron.dart`.

### Apps and validation

- `apps/agentd/bin/agentd.dart`, `packages/agent_gateway/lib/src/http_api.dart`.
- `apps/agent_flutter/lib/agent_api_client.dart`, UI controllers.
- `apps/agentd/web/app.js`, `index.html`.
- `.github/workflows/ci.yml`, `scripts/validate.sh`, `scripts/flutter_validate.sh`, `scripts/web_ui_validate.sh`, `scripts/smoke_agentd.sh`.

## 4. Risiko teknis yang muncul saat membaca code

Temuan ini bukan klaim bug pasti; perlu test/regresi sebelum mengubah source:

1. **Flutter API error transparency:** `capabilities()`, `doctor()`, `listSessions()`, `listApprovals()`, `listEvents()` mengembalikan `{}`/`[]` pada HTTP error. UI berpotensi menampilkan state kosong saat sebenarnya 401/403/5xx.
2. **Flutter delete memory path:** `deleteMemory(id)` menyisipkan ID pada path tanpa `Uri.encodeComponent`, berbeda dengan `decideApproval`. ID saat ini mungkin UUID sederhana, tetapi API sebaiknya konsisten.
3. **Flutter WebSocket query:** `streamChat()` membangun query `?token=$token` lewat interpolasi string. Gunakan URI `queryParameters` dan uji karakter khusus pada token; pastikan lifecycle channel/sink saat cancel. `deleteMemory()` juga menyisipkan ID langsung di path tanpa encoding, berbeda dengan `decideApproval()` yang memakai `Uri.encodeComponent`.
4. **Provider health duplication:** router `ProviderHealth` dan provider `CircuitBreaker` berbeda state; dokumentasikan dan pastikan tidak double count/selection race.
5. **Email gateway TLS/inbound:** `EmailGateway` memiliki opsi STARTTLS, tetapi `onBadCertificate: (_) => true` menerima sertifikat invalid. `agentd` tidak memasang inbound receiver; `pushInbound()` hanya hook class. Dokumentasikan channel sebagai outbound-only sementara dan perbaiki certificate validation sebelum penggunaan direct STARTTLS.
5. **MCP HTTP protocol/security:** `HttpMcpClient` default ke `2025-11-25`, sementara jalur modern `2026-07-28` dinegosiasikan oleh stdio client. `registry_mcp.dart` tidak menerapkan `SsrfGuard` ke URL HTTP karena dianggap admin-configured; hanya operator tepercaya boleh mengubahnya. Ada `streamable_http.dart` standalone lama yang belum dipakai loader aktif. Perlu hardening/penyederhanaan dan test interop eksplisit.
7. **Scheduler at-least-once:** crash setelah platform menerima pesan tetapi sebelum local ack dapat menyebabkan duplikasi. Gateway idempotency belum dijamin.
8. **Sandbox availability:** `SandboxKind.none` bukan isolasi OS. Pastikan mode tool berisiko tetap fail-closed dan deployment tidak mengasumsikan proot sebagai security boundary.

Karena task yang diminta adalah rekonsiliasi dokumentasi, temuan kode ini dicatat sebagai backlog; source code tidak diubah dalam paket dokumen.

## 5. Bukti CI

Workflow CI pada snapshot mengatur Dart 3.13.4 dan Flutter 3.47.5. Run `42636270018` completed/success pada SHA yang diaudit. Workflow checks: Bash/Python syntax, Dart pub get, strict analysis, seluruh package tests, CLI calculator/chat smoke, setup/config smoke, compile `tiko`/`agentd`/`agent_cli`, daemon HTTP API smoke, Flutter pub get/analyze/test/build web.

CI tidak menguji koneksi provider cloud, akun channel nyata, semua MCP server, penetrasi security, dan UI visual setiap device.

## 6. Scope paket dokumentasi

Paket ini mengganti dokumen kanonis/entry-point yang stale dan menambahkan status/audit terbaru. Laporan milestone tanggal tertentu tetap dipertahankan sebagai sejarah; jangan mengubah hasil historis agar terlihat dibuat pada HEAD sekarang.
