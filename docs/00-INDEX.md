# Indeks Dokumentasi Tiko-Agent

**Source snapshot:** commit `ddb7ceb` pada branch `main`.

**Terakhir diperbarui:** 20 November 2026.

**Aturan status:** source code dan test adalah bukti utama. “Tersedia sebagai library” tidak sama dengan “terhubung ke runtime/user command”. Status CI harus dibaca dari [GitHub Actions](https://github.com/kiosmarmer-commits/Tiko-Agent/actions).

## Urutan baca

| Urutan | Dokumen | Fokus |
|---|---|---|
| 1 | [INSTALL.md](../INSTALL.md) | Instalasi dan operasi |
| 2 | [01-ARSITEKTUR.md](01-ARSITEKTUR.md) | Package graph dan aliran runtime |
| 3 | [02-PROVIDER-AI.md](02-PROVIDER-AI.md) | Provider, routing, health, circuit breaker |
| 4 | [03-TOOLS-MCP-SKILLS.md](03-TOOLS-MCP-SKILLS.md) | Tool registry, sandbox, MCP, skills |
| 5 | [04-MEMORI-DB-PENCARIAN.md](04-MEMORI-DB-PENCARIAN.md) | Store, FTS, vector, RAG |
| 6 | [05-SCHEDULER-BOT-GATEWAY.md](05-SCHEDULER-BOT-GATEWAY.md) | Scheduler, bot, gateway, delivery |
| 7 | [06-AGENT-ALGORITMA-SELFLEARNING.md](06-AGENT-ALGORITMA-SELFLEARNING.md) | Loop, evaluasi, self-learning |
| 8 | [07-KEAMANAN-OBSERVABILITAS.md](07-KEAMANAN-OBSERVABILITAS.md) | Security dan telemetry |
| 9 | [08-PEDOMAN-PENGEMBANGAN.md](08-PEDOMAN-PENGEMBANGAN.md) | Prosedur perubahan aman |
| 10 | [09-DESAIN-GUI.md](09-DESAIN-GUI.md) | Token UI, gaya flat modern, paritas lintas platform |
| 11 | [10-WEB-UI.md](10-WEB-UI.md) | Dashboard web agentd (Flutter Web), sesi cookie, auto-open |
| 12 | [11-CHAT-UX-MODERN.md](11-CHAT-UX-MODERN.md) | Audit dan rancangan UX chat modern (markdown+copy, attachment, artifact panel, status strip) |
| 13 | [12-HERMES-FITUR-BERIKUTNYA.md](12-HERMES-FITUR-BERIKUTNYA.md) | Pemetaan fitur Hermes → Tiko (discovery, hooks, cron, dsb.) |
| 14 | [13-TUGAS-TERJADWAL-RISET.md](13-TUGAS-TERJADWAL-RISET.md) | Fase D — riset otomatis terjadwal + papan Kanban |

## Status implementasi

| Area | Status | Batasan penting |
|---|---|---|
| Agent loop, cancellation, budget, tool orchestration | Implemented | Perubahan harus menjaga contract test agent_core |
| Provider AI, routing, health, circuit breaker | Implemented/conditional | Memerlukan endpoint dan secret provider |
| Memory SQLite/JSON, FTS, vector, RAG, layers | Implemented/conditional | SQLite native tidak selalu tersedia; JSON fallback degraded |
| Tools, sandbox, MCP stdio/HTTP, OAuth | Implemented/conditional | Sandbox OS dan secret dapat membuat capability unavailable |
| Browser CDP lokal/remote | Implemented/conditional | Chrome atau backend remote harus tersedia |
| Scheduler dan job delivery | Implemented | Channel tujuan harus aktif |
| Telegram/Discord/Slack/WhatsApp/Email/Signal/Matrix/LINE | Implemented/conditional | Masing-masing membutuhkan konfigurasi dan credential |
| Teams | Implemented | Outbound webhook dan inbound Bot Framework activity melalui `/webhooks/teams` dengan bearer token |
| ACP resources | Implemented | List/read/write resource terdaftar, resource read-only, dan command fail-closed |
| Wake-word Porcupine/openWakeWord | Partial | Native engine belum terhubung; tersedia fallback energy/keyword |
| Event Hooks (Hermes-parity P1) | Implemented | Config `hooks:` (event/webhook/script); hasil di `hook.executed` + snapshot `/v1/plugins`; GUI settings menyusul |
| Cron pause/resume + attach skill + [CRON_FAILURE] (Hermes-parity P2) | Implemented | Endpoint pause/resume + PATCH `paused`/`skill`; status run (`last_status`, `failure_streak`) di `/v1/jobs` |
| @ Context references @file/@folder/@git-diff/@url (Hermes-parity P3) | Implemented | Ekspansi fail-closed di `chatWithStatus` (command `/` dan code fence dikecualikan); event `context.expanded`; chip UI web menyusul |
| Endpoint OpenAI-compat `/v1/chat/completions` (Hermes-parity P4) | Implemented | Non-stream + SSE (single-delta + `[DONE]`); system/transcript/user-terakhir; error shape OpenAI; auth `/v1` sama; usage estimasi len/4 |
| Tiko sebagai MCP Server (stdio) | Implemented | `tiko mcp` — `McpAgent` JSON-RPC 2.0 stdio; tools `tiko_chat` (turn penuh + gate fail-closed), `tiko_cancel`, `tiko_tools`, `tiko_sessions`, `tiko_status`; sesi `mcp:*` terpisah; hanya stdio, tanpa streaming |
| Markdown + tombol salin di chat (Chat-UX C1) | Implemented | `TikoMarkdownView` subset markdown + code block tersalin sendiri; tombol Salin per-pesan asisten; tanpa dependency baru; bukan CommonMark penuh |
| Lampiran file end-to-end (Chat-UX C2) | Implemented | Inline base64 di `POST /v1/messages` + WS (maks 4 file, 2 MiB, mime allowlist, fail-closed); runtime ingest `[lampiran:]` (Fase A superset) 64 KiB/file 128 KiB total; gambar kini diteruskan ke provider vision (Fase A.4); picker Web via `dart:html`, desktop → `@file:` |
| Embedded file view + kartu diff di chat (Chat-UX C3) | Implemented | `ChatArtifactPanel` di kanan chat (≥1100px) / overlay mobile; chip `@file:` di pesan; kartu file + Lihat/Diff vs `.bak`; listing global (filter per-sesi belum ada endpoint-nya); sumber otomatis kartu dari tool trace menyusul di C4 |
| Status proses turn + tombol Stop (Chat-UX C4) | Implemented | WS frames `chat.status`/`chat.toolStart`/`chat.tool` (args tersanitasi, hanya `path` tool file); strip spinner + tool aktif; ringkasan collapsible N tool + durasi + error; Stop kooperatif via `rt.cancelTurn` (frame `cancel`/`cancel_ack`); HTTP `/v1/messages` tetap sinkron |
| Batch processing + trajektori export (Hermes-parity P5) | Implemented | `tiko batch run --tasks JSONL --concurrency 1..16` (chatWithStatus + TrajectoryLogger + laporan `data/batch/`); `tiko batch export --out` JSONL/ShareGPT, redaksi secret default |
| Project context file TIKO.md/AGENTS.md/CLAUDE.md/GEMINI.md (Fase A.1) | Implemented | `resolveProjectContextFile` + CLI `tiko context`; disuntik ke system prompt tiap turn (prioritas TIKO.md > AGENTS.md > CLAUDE.md > GEMINI.md); cap 12.000 char penanda jujur; fail-closed |
| Zip auto-extract saat attach (Fase A.2) | Implemented | `ingestAttachments` ekstrak zip ke `data/uploads/<sesi>/` (anti traversal/absolut, 500 entry, 16 MiB/entry, 64 MiB total) + tool `unzip_archive` untuk turn agent; listing teratas inline; fail-closed |
| Ekstraksi teks dokumen PDF/DOCX/ODT/XLSX/PPTX (Fase A.3) | Implemented | `extractDocumentText` pure-Dart best-effort (`doc_extract.dart`, paket `archive`); file mentah juga disimpan ke uploads sebagai path referensi; budget 64 KiB/file; semua gagal → catatan juhur (“fail-closed”) |
| Vision/multimodal image input (Fase A.4) | Implemented (provider-level) | `ChatImage` di `ChatMessage` dikirim ke openai_compat/azure (image_url), anthropic (blok image), gemini (inline_data), ollama_native (images[]), openai_responses (input_image); maks 4 gambar turn, 4 MiB/gambar; passthrough bergantung gateway mengirim bytes raw (web chat base64 → bytes) |
| Auto coding/debugging loop `tiko fix` + tool `verify_project` (Fase B) | Implemented | `CodeLoopRunner` (tiko_runtime): turn agent (tool write/patch difilter) → exit 0 adalah gate sukses, bukan klaim model → umpan balik output-ke gagal ke turn berikut; maks 8 iterasi (clamp); checkpoint .tiko/checkpoints sebelum edit + jalur rollback; verifikasi argv-exec tanpa shell bila tidak ada OS sandbox; `tiko fix "<tugas>" --verify "<cmd>"` |
| Orkestra bot team satu panggilan `tiko team` + tool `bot_team` (Fase C) | Implemented | `BotTeamRunner` (tiko_runtime): planner mendekomposisi tujuan → JSON DAG tervalidasi (fallback 1 node fail-closed) → DAG dieksekusi paralel per-wave (maks 8 konkurensi, 12 node) → sintesis summarizer (gabungan deterministik bila tidak ada) → review critic → gate `--verify` opsional + turn perbaikan terbatas (mewarisi kontrak exit-0 Fase B); tim tersimpan di `data/teams/<id>.json`, laporan run di `data/teams/runs/`; event `team.*` ke EventBus/`/v1/stream`; REST `/v1/teams` (list/get/save/PUT/DELETE/run/laporan, 501 bila host tak konfigurasi); CLI `tiko team list|show|save|delete|run` |
| Home Assistant provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| Tuya provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| SONOFF/eWeLink CUBE provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| Google Home | Conditional via Home Assistant | Tidak ada direct Google Home API provider di repo |
| Self-learning/reflection | Implemented with guards | Sintesis tetap dibatasi gate, score, dan approval |
| Flutter client/widgets | Implemented/conditional | Memerlukan Flutter SDK dan daemon/API |
| Web dashboard agentd (Jalur A) | Implemented/conditional | Flutter Web sebagai satu-satunya webRoot + cookie sesi same-origin + auto-open browser; butuh `flutter build web` sebelum daemon dapat menyajikan UI |
| Simpul vault/index | Implemented | Modul terpisah dari agent runtime utama |

## Kontrak dokumentasi

- Setiap fitur publik harus punya lokasi source, entry point, konfigurasi, batasan, dan test yang dapat ditemukan.
- Algoritma yang memengaruhi score, ranking, routing, prediksi, memory retention, atau approval harus didokumentasikan bersama invariant dan fixture regresinya.
- Klaim “full”, “real-time”, “secure”, atau “production-ready” harus memiliki bukti test/integration yang sesuai; jika belum, gunakan label `Partial` atau `Conditional`.
- Dokumen historical boleh dipertahankan sebagai arsip, tetapi tidak boleh menjadi rujukan status HEAD tanpa label tanggal dan commit.

## Validasi terdokumentasi

Validasi lokal pada snapshot ini:

- `dart analyze packages/agent_tools packages/agent_gateway apps/agentd --fatal-warnings`: tidak ada error/warning fatal; tersisa info lint nonfatal.
- OAuth dan smart-home tests: lulus.
- `agent_core`, `agent_memory`, dan `agent_tools`: lulus dengan dua random-order seeds.
- `tiko_runtime`: suite lokal sangat lambat dan tidak selesai dalam sesi audit; status final mengikuti CI remote.

## Label status

- **Implemented** — kode aktif, wiring, dan test kontrak tersedia.
- **Implemented/conditional** — kode dan wiring tersedia, tetapi environment/credential diperlukan.
- **Implemented as library** — API provider tersedia, tetapi belum otomatis menjadi command/runtime feature.
- **Partial** — jalur utama tersedia, tetapi ada bagian penting yang belum terpenuhi.
- **Not implemented** — belum ada bukti source/test yang memadai.
- **Historical** — catatan lama; tidak merepresentasikan HEAD sekarang.
