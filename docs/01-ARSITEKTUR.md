# 01 — Arsitektur Aktual Tiko Agent

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be` (9 November 2026).

Dokumen ini menjelaskan komposisi source saat ini. Diagram dan pseudocode adalah model konseptual, bukan kontrak API Dart yang harus disalin apa adanya.

## 1. Topologi

```text
CLI (tiko / agent_cli)   Flutter UI   Web UI   Telegram/Discord/Email
          \                 |          |             /
           \----------------+----------+------------/
                            |
                 agentd / HttpApiServer
            auth · webhook · WS · gateway mapping
                            |
                      TikoRuntime
      config/provider factory/approvals/memory/tools/jobs
                            |
          +-----------------+-------------------+
          |                 |                   |
      AgentLoop           Router             Scheduler
   context + budget     tier + health       cron + delivery
   permission + tools   fallback            ack/retry
          |                 |
      ToolRegistry      LlmProvider(s)
    built-in/script/MCP  mock / OpenAI-compatible /
      sandboxed          Ollama / Anthropic / Gemini
          |
    MemoryStore + SessionStore + ledgers + audit
```

## 2. Workspace aktual

| Paket/aplikasi | Tanggung jawab |
|---|---|
| `agent_core` | Kontrak model/tool/memory, `AgentLoop`, `Router`, context builder/expander, budget, plan/reflection, skills dan evaluation primitives |
| `agent_providers` | Adapter LLM/DecisionProvider, Ollama embedder, circuit breaker provider |
| `agent_tools` | Built-in tools, registry, shell/script sandbox, SSRF, MCP stdio/HTTP, CDP browser, tool forge dan utility tools |
| `agent_memory` | SQLite via `sqlite3`, FTS5, JSON persistent fallback, owner-scoped memory, session file store |
| `agent_scheduler` | Job store, cron parser, zona waktu, scheduler tick, delivery state/retry |
| `agent_gateway` | Telegram, Discord, Email, HTTP/WebSocket API, webhook endpoint, STT/TTS/voice helpers |
| `agent_security` | Permission gate, sanitasi/redaksi, audit dan kill-switch primitives |
| `agent_calc` | Desimal eksak, parser/evaluator, satuan/keuangan/statistik/tanggal, isolate sandbox |
| `tiko_runtime` | Composition root yang menyatukan provider, storage, registry, broker, skill ledgers, offline queue, scheduler dan subagent |
| `apps/tiko` | CLI utama Tiko/Pasitiko, setup/config/doctor/skills/approvals/calc/daemon commands |
| `apps/agentd` | Host daemon, bootstrap gateway, MCP startup, token/API dan scheduler delivery sink |
| `apps/agent_cli` | CLI agent minimal/legacy |
| `apps/agent_flutter` | Client Flutter Android/Web, proyek terpisah dari Dart workspace |

## 3. Lifecycle runtime

`TikoRuntime.create()` melakukan urutan utama berikut:

1. Membaca `config/agent.yaml` melalui `TikoConfig`; validasi fatal menghentikan runtime normal.
2. Membuat provider dari `ProviderFactory`; `decision` opsional. Bila disabled, router memakai heuristic (atau JSON fallback jika dikonfigurasi).
3. Membuat embedder hanya bila `memory.embed.enabled` aktif.
4. Membuka SQLite memory store; bila gagal, memakai `PersistentMemoryStore` JSON dengan status backend degraded.
5. Mendeteksi host sandbox dan membuat `SandboxRunner`.
6. Memuat skills, jobs, tools, script tools (hanya bila sandbox tersedia), dan MCP loader.
7. Memulihkan approval ledger, skill approval ledger dan skill metrics ledger.
8. Mendaftarkan subagent runtime dan tool forge yang memerlukan sandbox.

`agentd` kemudian mengambil instance lock. Hanya daemon yang memegang lock yang menjalankan MCP child processes, menyiapkan token API, dan men-start gateway/scheduler. Jangan menganggap pembuatan runtime oleh CLI otomatis menyalakan MCP daemon.

## 4. Aliran satu pesan

1. Gateway/API memetakan pesan menjadi `InboundMessage`, menerapkan autentikasi/allowlist/rate limit pada channel terkait.
2. Router memilih tier/provider; `route explain` memperlihatkan alasan, tier mapping, provider health dan fallback events.
3. ContextBuilder menyusun history, memory retrieval yang relevan, skill yang cocok dan tool specs. Input `@file`, `@dir`, `@git`, `@url` dapat diperluas melalui ContextExpander jika di-wire.
4. AgentLoop menjalankan ReAct. Budget menghentikan loop saat iterasi/token/waktu/tool limit tercapai.
5. Pemeriksaan izin dan konfirmasi berlangsung berurutan sebelum eksekusi. Eksekusi paralel memakai opt-in `ToolSpec.parallelSafe`: hanya tool yang telah diaudit sebagai read-only/pure boleh overlap. Tool lain (termasuk extension yang metadata-nya belum menyatakan aman) menjadi barrier serial. Hasil workspace dan eksternal tetap diperlakukan sebagai data tidak tepercaya; hanya sumber eksternal yang mengaktifkan session taint untuk konfirmasi berikutnya.
6. Loop mendeteksi pengulangan tool+args, melakukan compaction bila perlu, mengirim jawaban dan menyimpan pesan/memori best-effort.
7. Turn sukses dengan beberapa tool dapat menghasilkan `SKILL.md` draft melalui SkillSynthesis; draft belum aktif sebelum gating/approval.

## 4.1 Tool concurrency dan trust boundary

`ParallelToolRunner` mempertahankan urutan panggilan dan mengelompokkan hanya panggilan `parallelSafe` yang berurutan. Satu tool yang tidak aman/unknown menyelesaikan eksekusi sebelum tool setelahnya dimulai. `ToolSpec.parallelSafe` default `false`; resolver runtime mengambil nilai dari registry. Saat delta 10 November, opt-in hanya diberikan kepada `datetime`, `calc`, `list_dir`, `read_file`, dan `grep`. `web_search` tetap serial karena melakukan network fetch dan mutasi cache proses; MCP, script, browser, shell, write/patch, dan tool extension lain juga tetap serial kecuali diaudit dan diubah secara eksplisit.

`SecuritySanitizer` membungkus output yang berisi konten dari workspace (`read_file`, `list_dir`, `grep`, `probe`, `shell`) maupun sumber eksternal (`web_*`, HTTP, MCP, script, browser) ke envelope data tidak tepercaya. Hanya sumber eksternal yang menaikkan session taint; pembacaan workspace sendiri tidak lagi menyebabkan semua operasi medium berikutnya meminta approval tambahan. Operasi berisiko tetap tunduk pada permission gate normal.

## 5. Provider dan pemilihan model

`ProviderFactory` membangun `mock`, `openai_compat`, `ollama_native`, `anthropic`, dan `gemini`. Tier mapping opsional di `providers.tiers` menghubungkan tier 1/2/3 ke ID provider yang telah didefinisikan dan enabled. Bila tier tidak dipetakan, default provider digunakan; provider yang tidak sehat dilewati bila tersedia alternatif.

Ada dua state kesehatan yang perlu dibedakan:

- `ProviderHealth` berada di `agent_core.Router`, mencatat kegagalan/latensi dan pemilihan fallback.
- `CircuitBreaker` berada di `agent_providers` sebagai wrapper provider, dengan fase open dan half-open single-probe.

Keduanya belum satu state machine bersama; jangan menganggap angka/metrik keduanya identik.

## 6. Penyimpanan

- Memory facts/messages: SQLite via `sqlite3` + FTS5 jika native backend berhasil dibuka; fallback JSON persisten bila tidak.
- Session history: `FileSessionStore` pada file JSON dengan lock lintas proses dan refresh-under-lock.
- Jobs/offline queue/approval/capability/skill ledgers: file JSON di data directory sesuai komponen masing-masing.
- Vector index runtime: `BruteForceVectorIndex`; embedding dapat dimatikan. `sqlite-vec` bukan backend otomatis/default pada runtime.

## 7. Host dan batas deployment

Daemon bind default `127.0.0.1`; API memerlukan token kecuali `/health`. `API_HOST`, `API_PORT`, `TIKO_CONFIG`, gateway environment variables dan config file mengontrol deployment. Flutter/Web adalah client; server AI, tools dan background scheduler hidup pada daemon.

Sandbox host dapat berupa bubblewrap, Docker, SSH atau none. Mode none tidak memberi isolasi OS. Termux/proot tidak boleh didokumentasikan sebagai sandbox keamanan kuat.

## 8. Konfigurasi inti

Lihat `config/agent.yaml` untuk template kanonis. Bagian utama: `agent`, `providers`, `decision`, `memory`, `security`, `search`, `http`, `storage`, `api`, `mcp`, `scheduler`. Validasi dengan:

```bash
dart run apps/tiko/bin/tiko.dart config validate
dart run apps/tiko/bin/tiko.dart doctor
```
