# 12 — Referensi Fitur Hermes untuk Tiko-Agent (Rencana Lanjutan)

**Tanggal:** 21 November 2026
**Sumber:** [Hermes Agent Docs — Features Overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/overview) (Nous Research) + kode Hermes Agent di GitHub.
**Metode:** pemetaan fitur Hermes terhadap kode Tiko-Agent di `main` (source code + test = bukti utama).

## 1. Yang sudah paritas (tidak perlu dikaji ulang)

| Fitur Hermes | Implementasi Tiko |
|---|---|
| Pemilih model + live discovery (`/model`, picker) | `ModelDiscovery` (agent_providers): OpenAI-compat `GET {base}/models`, Ollama `GET {base}/api/tags`; cache TTL 15 menit; per-sesi via `POST /v1/providers/session` (PR #130 + lanjutan) |
| Cron / scheduled tasks + delivery ke platform | Scheduler terkelola `TikoRuntime` + delivery ack + retry; job CRUD + run-now (`GET /v1/jobs`) |
| Subagent delegation (isolated context) | `spawn_subagent` → nested `chatWithStatus` dengan child session, depth marker, budget/cancellation |
| Code execution ter-sandbox | `execute_code.dart`, `script_runner.dart`, sandbox OS (bubblewrap/docker/ssh/modal/daytona/vercel/singularity/sprites) |
| Checkpoints & rollback | `patch_file`, `rollback`, `list_checkpoints` |
| Context files otomatis | `packages/agent_core/lib/src/context_files.dart` (AGENTS.md/CLAUDE.md) |
| Skills + lifecycle + hub | Skill registry, draft → scan → golden eval → approval → rollback; skills hub hot-reload |
| Memory terkurasi lintas sesi + provider eksternal | Layered memory SQLite/JSON + adapter REST (RetainDB/ByteRover/Mem0-style) |
| Fallback providers + routing health | Router fallback chain + circuit breaker + tiers |
| Credential pools | `credential_pool.dart` |
| Prompt caching | `prompt_cache.dart` |
| MCP (stdio + HTTP) + per-server filtering | MCP manager + allowlist |
| Browser automation | CDP lokal + Browserbase/Browser Use/Firecrawl cloud |
| Voice (TTS/STT) + wake word | Voice loop Discord/CLI; wake word partial |

## 2. Gap yang layak diadopsi (urutan prioritas)

### P1 — Event Hooks (lifecycle hooks) — **Implemented**
- **Hermes:** jalankan kode/skrip kustom di titik lifecycle: sebelum/sesudah tool call, turn selesai, cron fire, delivery gagal — dipakai untuk logging, alert, webhook, guardrail, metrics.
- **Implementasi Tiko:** config top-level `hooks:` di `agent.yaml` — daftar mapping `{event, webhook/script, timeout_sec, env}`; `event` bisa nama event `EventBus` (`model.switched`, `approval.denied`, `memory.curated`, dsb.) atau `*` untuk semua.
- **Eksekusi:** `HookExecutor` (tiko_runtime) subscribe `events.stream`; fire-and-forget — kegagalan hook tidak pernah menggagalkan turn chat; event hasil sendiri (`hook.*`) tidak pernah memicu hook (anti-loop).
- **Webhook:** POST JSON `{event, at, data}`; status ≥ 400 dianggap gagal.
- **Script:** path relatif di dalam workspace (tanpa `..`/absolut — divalidasi ulang saat fire, fail-closed), dijalankan via `sh` dengan env minimal `PATH`, `TIKO_EVENT`, `TIKO_EVENT_DATA_JSON`, plus `env:` rule; timeout 1..120 detik → kill.
- **Validasi config:** aturan invalid dilompati dengan issue `fatal: false` (`hooks[N]…`) — config hook salah tidak pernah membunuh daemon.
- **Observabilitas:** hasil tiap fire di-emit balik sebagai event `hook.executed` `{rule, trigger, outcome, error?}`; snapshot rules + stats per target tersedia via `rt.hookSnapshot()` dan di `/v1/plugins` (`hooks`). GUI Pengaturan → Hooks menyusul.

### P2 — Job cron: pause/resume + attach skill + penanda kegagalan eksplisit — **Implemented**
- **Hermes:** job bisa pause/resume/edit, melampirkan skill, dan turn gagal dideklarasikan lewat penanda eksplisit (`[CRON_FAILURE]`) yang tercatat di last_status/failure streak.
- **Implementasi Tiko:** field `Job.paused` (persist; `_claim` melewati job paused — run/delivery yang sudah berjalan dibiarkan selesai, at-least-once) + `JobStore.setPaused` + endpoint `POST /v1/jobs/<id>/pause|resume` (501 bila host tak konfigurasi); PATCH & create menerima `paused` juga.
- **Attach skill:** field `Job.skill` (slug 1..64 tanpa spasi; `"all"` di PATCH menghapus lampiran) — dijadwalkan lewat REST (`/v1/jobs`) maupun tool `schedule_job`. Handler runtime fail-closed: skill hilang/`retired` membuat run gagal dengan pesan eksplisit; skill aktif di-prepend ke prompt run dan `recordUse` tercatat.
- **Status run:** `JobStore.recordSuccess/recordFailure` → `last_status` (`ok`/`failed`), `last_error` berprefiks `[CRON_FAILURE]`, dan `failure_streak` direset/bertambah; semua tampil di snapshot jobs (`/v1/jobs`) dan dipersist di `jobs.json`.

### P3 — `@ Context references` di chat
- **Hermes:** `@file`, `@folder`, `@git-diff`, `@url` diekspansi inline jadi konteks pesan.
- **Fondasi Tiko:** tool read/patch/artifact ada; web chat + TUI tinggal parser argumen pesan.
- **Desain sarankan:** parser `@` di `chatWithStatus` (fail-closed pada path di luar workspace + ukuran maksimum), deteksi `@url` lewat tool fetch existing; indikator ekspansi di UI web (chip di atas composer).

### P4 — Endpoint OpenAI-compat (`/v1/chat/completions`) di agent_gateway
- **Hermes:** expose agent sebagai endpoint OpenAI-compatible agar bisa dipakai Open WebUI/LibreChat/dll.
- **Fondasi Tiko:** `HttpApiServer` sudah streaming SSE (voice/progressive stream), auth bearer/cookie sudah ada, chat sinkron lewat `TikoRuntime.chat`.
- **Desain sarankan:** map `messages` → session ephemeral, streaming SSE, tetap bind loopback + auth; jangan melewati auth check/Host allowlist yang sudah ada.

### P5 — Batch processing + trajektori export (eval/self-learning)
- **Hermes:** jalankan agent atas ribuan prompt paralel; ekspor trajektori terstruktur untuk eval/training.
- **Fondasi Tiko:** self-learning/reflection + audit store + runs API sudah merekam aktivitas.
- **Desain sarankan:** command `tiko batch run --tasks file.jsonl --concurrency N` + ekspor JSONL trajektori dari runs/audit; gate concurrency mengikuti budget provider.

### P6 — Kontrol routing per provider (sort/whitelist/cost)
- **Hermes:** whitelists/blacklists, sorting, prioritas per permintaan.
- **Fondasi Tiko:** tiers + preferredProviderId/session override + fallback chain sudah ada.
- **Desain sarankan:** cukup tambah `providers.chat.<id>.weight/cost` opsional ke urutan fallback bila fitur dianggap perlu; jangan ubah kontrak Router tanpa kebutuhan nyata.

## 3. Yang sengaja tidak diadopsi

- **Chronos (cron via infra pihak ketiga scale-to-zero):** Tiko daemon self-host; ticker in-process sudah memadai dan tanpa ketergantungan infra eksternal.
- **Plugin Python drop-in (`~/.hermes/plugins/`):** Tiko sudah punya plugin registry + consent + MCP; menambah runtime interpreter Python menambah permukaan keamanan tanpa kebutuhan eksplisit.

## 4. Langkah tindak lanjut

1. ~~Implementasi P1 (Event Hooks)~~ — **selesai**: config `hooks:` + HookExecutor (webhook/script) + observability `hook.executed` + snapshot `/v1/plugins`; wiring GUI menyusul di PR berikutnya.
2. ~~P2 pause/resume job~~ — **selesai**: `Job.paused` + endpoint `/v1/jobs/<id>/pause|resume` + `Job.skill` (fail-closed lewat skill registry) + `last_status`/`failure_streak` dengan penanda `[CRON_FAILURE]`.
3. P3–P5 menyusul setelah P2 stabil; masing-masing berdiri sendiri.
