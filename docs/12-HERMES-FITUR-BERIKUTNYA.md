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
- **Observabilitas:** hasil tiap fire di-emit balik sebagai event `hook.executed` `{rule, trigger, outcome, error?}`; snapshot rules + stats per target tersedia via `rt.hookSnapshot()`, di `/v1/plugins` (`hooks`), dan di `GET /v1/hooks`.
- **GUI Pengaturan → Hooks (SETTINGS-HOOKS):** CRUD lengkap lewat `POST/PATCH/DELETE /v1/hooks[/<n>]` + test fire `POST /v1/hooks/test` (`{index}`) — aturan berlaku live dan dipersist ke config `hooks:` lewat `ConfigStore` (atomik, terevisi); halaman Flutter menampilkan hook aktif, statistik sukses/gagal, form add/edit (webhook/script, timeout, env), dan tombol test.

### P2 — Job cron: pause/resume + attach skill + penanda kegagalan eksplisit — **Implemented**
- **Hermes:** job bisa pause/resume/edit, melampirkan skill, dan turn gagal dideklarasikan lewat penanda eksplisit (`[CRON_FAILURE]`) yang tercatat di last_status/failure streak.
- **Implementasi Tiko:** field `Job.paused` (persist; `_claim` melewati job paused — run/delivery yang sudah berjalan dibiarkan selesai, at-least-once) + `JobStore.setPaused` + endpoint `POST /v1/jobs/<id>/pause|resume` (501 bila host tak konfigurasi); PATCH & create menerima `paused` juga.
- **Attach skill:** field `Job.skill` (slug 1..64 tanpa spasi; `"all"` di PATCH menghapus lampiran) — dijadwalkan lewat REST (`/v1/jobs`) maupun tool `schedule_job`. Handler runtime fail-closed: skill hilang/`retired` membuat run gagal dengan pesan eksplisit; skill aktif di-prepend ke prompt run dan `recordUse` tercatat.
- **Status run:** `JobStore.recordSuccess/recordFailure` → `last_status` (`ok`/`failed`), `last_error` berprefiks `[CRON_FAILURE]`, dan `failure_streak` direset/bertambah; semua tampil di snapshot jobs (`/v1/jobs`) dan dipersist di `jobs.json`.

### P3 — `@ Context references` di chat — **Implemented**
- **Hermes:** `@file`, `@folder`, `@git-diff`, `@url` diekspansi inline jadi konteks pesan.
- **Implementasi Tiko:** `expandContextRefs()` (tiko_runtime) dipanggil di awal `chatWithStatus` — semua channel (CLI/web/gateway/cron) mendapat ekspansi; perintah internal (`/…`) dan isi code fence tidak disentuh. Sintaks satu token: `@file:<rel>`, `@folder:<rel>`, `@git-diff`, `@url:<http(s)://…>`.
- **Fail-closed:** path relatif workspace saja (tanpa `..`/`~`/absolut, tervalidasi ulang setelah normalisasi); file ≤ 64 KiB dan bukan biner; folder listing ≤ 200 entri / depth 3; URL GET ≤ 64 KiB, hanya http(s), timeout 15s; maks 8 ref/pesan; budget total ≤ 96 KiB.
- **Gagal jujur:** ref invalid diganti penanda inline `[@<ref> gagal: <alasan>]` — pesan tetap terkirim, tidak ada konten bocor keluar workspace.
- **Observability:** setiap ekspansi memancarkan event `context.expanded {session_id, ok, failed, refs[].ref/kind/status/bytes/error}`. Composer Flutter menampilkan chip visual per context ref (`@file:`/`@dir:`/`@url:`/`@git:`) plus autocomplete (builtin + path workspace via `/v1/artifacts`, debounce).

### P4 — Endpoint OpenAI-compat (`/v1/chat/completions`) di agent_gateway — **Implemented**
- **Hermes:** expose agent sebagai endpoint OpenAI-compatible agar bisa dipakai Open WebUI/LibreChat/dll.
- **Implementasi Tiko:** `POST /v1/chat/completions` di `HttpApiServer` — auth bearer/cookie + Host allowlist + bind loopback sama seperti `/v1` lain (tidak ada jalur tanpa auth).
- **Komposisi prompt:** `system` digabung ke blok `[system]…[/system]`, transcript percakapan sebelumnya disematkan sebagai konteks, user message terakhir diletakkan paling akhir agar instruksi terbaru dominan. Role `tool`/`function`, format invalid, atau tanpa user message → 400 (fail-closed).
- **Body:** `{model?, messages, stream?, session_key?, user_key?}` — `session_key` default `openai:default`, `user_key` default `openai`, channel `http` — sesi terpisah dari UI web. Content string maupun array parts `[{type:'text',…}]` didukung.
- **Respons non-stream:** bentuk `chat.completion` penuh (`id chatcmpl-…`, `choices[0].message`, `finish_reason: stop`, `usage` estimasi kasar len/4 — BUKAN token count akurat).
- **Streaming:** `text/event-stream` satu delta berisi jawaban penuh + delta `finish_reason: stop` + `data: [DONE]` (progressive-delivery satu potong, bukan token-level).
- **Error shape:** OpenAI `{error:{message,type,code}}` agar klien pihak ketiga menampilkan apa adanya; cap prompt terkomposisi 400.000 karakter.

### P5 — Batch processing + trajektori export (eval/self-learning) — **Implemented**
- **Hermes:** jalankan agent atas ribuan prompt paralel; ekspor trajektori terstruktur untuk eval/training.
- **Implementasi Tiko:** command `tiko batch run --tasks file.jsonl [--concurrency N] [--label L]` — task JSONL (`{"id": opsional, "prompt": wajib}`) dijalankan paralel lewat `BatchRolloutRunner` (agent_core, urutan hasil deterministik) di atas `rt.chatWithStatus`, tiap turn tercatat ke `data/trajectories/traj-<tanggal>.jsonl`, laporan agregat tersimpan di `data/batch/`.
- **Gate concurrency:** `--concurrency` divalidasi 1..16 (di luar rentang ditolak, bukan diam-diam dicekam); budget per-turn tetap ditegakkan `BudgetGuard` di dalam tiap turn.
- **Export:** `tiko batch export --out out.jsonl [--sharegpt] [--no-redact] [--exclude-session ID]` — ekspor JSONL trajektori (atau format ShareGPT untuk SFT/RL) dengan redaksi secret aktif secara default; file output yang sudah ada ditolak agar tidak tertimpa.

### P6 — Kontrol routing per provider (sort/whitelist/cost) — **Implemented**
- **Hermes:** whitelists/blacklists, sorting, prioritas per permintaan.
- **Fondasi Tiko:** tiers + preferredProviderId/session override + fallback chain sudah ada.
- **Implementasi:** `providers.chat.<id>.weight` (int, default 1; >= 0) dan `providers.chat.<id>.cost` (angka >= 0, default null/tak diketahui) di `tiko_config.dart`; validasi non-fatal (issue `providers.chat.<id>.weight|cost`, nilai invalid diabaikan, runtime tidak mati). Fallback chain dibangun `TikoConfig.fallbackChainIds(primary)`: primary/default tetap di depan, lalu provider enabled diurutkan weight desc → cost asc → urutan config (sort stabil via index; `List.sort` Dart tidak stabil); provider disabled tidak pernah masuk chain. Router tetap memakai kontrak `fallbackOrder` lama (tanpa perubahan kontrak Router); `tierProviders`, `preferredProviderId`, dan `enabled: false` (blacklist eksplisit) tetap bekerja seperti sebelumnya. Cost juga memengaruhi scoring dinamis: ctor param opsional `Router.providerCosts` memberi penalti proporsional (maks 0.1) pada pemilihan primary — capability/local/health selalu menang atas cost; tanpa cost di config perilaku identik; penalti terlihat di `tiko route explain`.
- **Uji:** `p6_provider_routing_test.dart` (9) — perilaku lama tanpa weight/cost, weight desc, cost asc pada weight sama, weight > cost, disabled keluar chain, tie urutan config, invalid non-fatal, primary selalu terdepan, cost int → double.

### P7 — Orkestra bot team satu panggilan (Fase C) — **Implemented**
- **Hermes/Claude Code:** planner mendekomposisi tujuan, anggota tim
  terspesialisasi bekerja paralel dengan konteks dibagi, hasil disintesis dan
  dikritik.
- **Implementasi Tiko:** tool `bot_team` + `runBotTeam` (tiko_runtime) —
  plan → DAG paralel → sintesis → review → gate verifikasi objektif opsional
  (mewarisi kontrak exit-0 Fase B); tim tersimpan (`tiko team save`, REST
  `/v1/teams`) dengan anggota `AgentSpec` penuh; laporan run di
  `data/teams/runs/`; event `team.*`. Detail algoritma: dok 06 §10.

## 3. Yang sengaja tidak diadopsi

- **Chronos (cron via infra pihak ketiga scale-to-zero):** Tiko daemon self-host; ticker in-process sudah memadai dan tanpa ketergantungan infra eksternal.
- **Plugin Python drop-in (`~/.hermes/plugins/`):** Tiko sudah punya plugin registry + consent + MCP; menambah runtime interpreter Python menambah permukaan keamanan tanpa kebutuhan eksplisit.

## 4. Langkah tindak lanjut

1. ~~Implementasi P1 (Event Hooks)~~ — **selesai**: config `hooks:` + HookExecutor (webhook/script) + observability `hook.executed` + CRUD API/GUI `Settings → Hooks` (SETTINGS-HOOKS).
2. ~~P2 pause/resume job~~ — **selesai**: `Job.paused` + endpoint `/v1/jobs/<id>/pause|resume` + `Job.skill` (fail-closed lewat skill registry) + `last_status`/`failure_streak` dengan penanda `[CRON_FAILURE]`.
3. ~~P3 @ context references~~ — **selesai**: `expandContextRefs()` di `chatWithStatus` (@file/@folder/@git-diff/@url, fail-closed, event `context.expanded`); chip + autocomplete di composer Flutter.
4. ~~P4 endpoint OpenAI-compat~~ — **selesai**: `POST /v1/chat/completions` (system+transcript+user-terakhir, stream/non-stream, error shape OpenAI, cap 400k karakter).
5. ~~P5 batch processing + trajektori export~~ — **selesai**: `tiko batch run --tasks/--concurrency/--label` (BatchRolloutRunner + trajektori JSONL + laporan `data/batch/`) dan `tiko batch export --out` (JSONL/ShareGPT, redaksi aktif).
6. ~~P6 kontrol routing per provider~~ — **selesai**: `providers.chat.<id>.weight/cost` + `TikoConfig.fallbackChainIds` (weight desc, cost asc, config order stabil); lihat §2 P6.
7. ~~Tugas terjadwal riset otomatis (Pulsa-parity + riset digest)~~ — **selesai (Fase D)**: lihat [13-TUGAS-TERJADWAL-RISET.md](13-TUGAS-TERJADWAL-RISET.md).
8. **Generative UI standar A2UI (Fase E)** — rancangan lengkap: lihat [14-A2UI-GENERATIVE-UI.md](14-A2UI-GENERATIVE-UI.md); pendekatan hibrida (grammar `genui` tetap didukung, protokol A2UI v1.0 sebagai target baru, adapter tunggal di `tiko_widgets`).
9. ~~Chat-UX live progress (laporan Codex item 3–5)~~ — **selesai**: TUI menampilkan spinner "Thinking…" + label tool live (`TuiProgress.status`), Ctrl-C/ESC membatalkan turn kooperatif via `rt.cancelTurn`, input saat turn dibuang, dan ringkasan tool setelah respons (`tools: N call · M token` + durasi per-tool). GUI Flutter menerima streaming token-level via frame WS `chat.delta` (`onTextDelta` di-relay agentd, sudah tersanitasi runtime; controller mengakumulasi bubble parsial dan frame `text` final tetap sinkron). Endpoint HTTP `POST /v1/messages` mendukung progress live via Server-Sent Events (`stream: true` atau `Accept: text/event-stream`) — frame status/tool/delta sama dengan WS `/v1/stream`; klien tanpa stream tetap menerima JSON sinkron.
10. ~~Hermes S6 fitur lanjutan session history~~ — **selesai**: pin/archive per sesi (`setPinned`/`setArchived` + PATCH `/v1/sessions/<id>`), bulk delete (`POST /v1/sessions/delete-bulk`), duplicate/fork (`POST /v1/sessions/<id>/duplicate`, id `<id>-fork-<ms>`), export transcript (`GET /v1/sessions/<id>/export?format=md|json|txt` dengan `Content-Disposition`), filter provider/model/channel di GUI history (`filter-history-channel`/`filter-history-meta`), dan indikator status sesi `last_failed` (dicatat via `SessionStore.markTurnOutcome` di akhir turn + metadata provider/model dari `Router.providerModels`). GUI: chip filter Semua/Disematkan/Arsip, mode pilih + hapus massal dengan konfirmasi, menu pin/arsip/duplikat/ekspor, dialog preview ekspor dengan tombol salin.
11. ~~Hermes S7 artifact panel terikat sesi~~ — **selesai**: filter artifact per sesi di panel chat (`chip-artifact-session-only`, korelasi `createdAt` sesi `SessionInfo.createdAt` + referensi `@file:` di pesan) dan dropdown filter di halaman Artifacts (`filter-artifacts-session`); download file (`GET /v1/artifacts/download` byte mentah + `Content-Disposition`, tersimpan ke folder Downloads/web browser; runtime `artifactsDownload` cap 8 MB); thumbnail gambar (runtime `artifactsRead` mengembalikan `is_image` + `content_base64` untuk png/jpg/jpeg/gif/webp ≤ 1 MB, GUI merender thumbnail 36×36 dan pratinjau `InteractiveViewer`); mode preview/code yang lebih lengkap (ToggleButtons Preview/Code/Diff — mode Code menampilkan nomor baris); publish/share ala Claude Artifacts (runtime `artifactsPublish` menyalin snapshot read-only ke `.tiko/published/` + share text, endpoint `POST /v1/artifacts/publish`, dialog GUI dengan tombol salin pesan share).
12. ~~Hermes S8 halaman GUI menerima surface dinamis A2UI~~ — **selesai**: halaman Tasks, Bots, Automation, Runs, Skills, dan Security kini merender surface A2UI dari agent lewat konvensi surfaceId prefix `page.<halaman>.` (didokumentasikan di system prompt addon + deskripsi tool `render_a2ui`); seksi `A2uiPageSurfaceSection` dirender di atas konten tiap halaman (desktop route + push mobile More), lazy-load detail saat di-expand, aksi tombol/input tetap melalui pipeline anti-replay host (`POST /v1/ui/actions` dengan `session_key` asal surface), tombol hapus dengan konfirmasi, tombol Kelola menuju halaman Surface, dan snapshot surfaces dimuat otomatis saat rute terkait dibuka.
13. ~~Hermes S9 TUI settings layar penuh~~ — **selesai**: `tiko settings` / `/settings` otomatis memakai TUI layar penuh gaya Hermes bila raw mode tersedia (fallback ke menu line-mode lama di pipe/CI): sidebar kategori (Provider, Keamanan, Runtime, Fitur, Provider lanjutan) dengan penanda dirty `*` per kategori, panel detail dengan cursor, pencarian lintas kategori (`/`), navigasi tab `(←/→/Tab/Shift-Tab)` dan `↑/↓`/`j`/`k`, preview perubahan tertunda (`p`) bergaya `path: lama → baru`, simpan batch ber-revisi via `ConfigStore.setPath` (`s`), reset (`r`), keluar ter-guard saat ada perubahan (`q` — tekan lagi), dan footer shortcut konsisten. Tambah `KeyType.esc` di tiko_tui (`decodeKeys`) untuk membatalkan mode cari/edit; input tidak valid tetap ditolak sebelum masuk daftar perubahan (ditulis ber-revisi, rollback tetap `tiko config rollback`).
14. ~~Hermes S10 onboarding wizard terpandu penuh~~ — **selesai**: `tiko setup --interactive` kini dijalankan oleh `runSetupWizard` (apps/tiko/lib/setup_wizard.dart): (1) deteksi provider otomatis dari env API key (`OnboardingProbe.detectFromEnv` — OpenAI/Anthropic/Gemini/DeepSeek/OpenRouter/Mistral/Groq/xAI/Together/Fireworks/NVIDIA/HF) + probe daemon Ollama `127.0.0.1:11434` dengan fallback mock; (2) test connection per provider sekaligus live model discovery satu GET (`OnboardingProbe.probe` — `GET {base}/models` Bearer untuk preset OpenAI-compat, `x-api-key`+`anthropic-version` untuk Anthropic `/v1/models`, `/api/tags` untuk Ollama; azure/bedrock ditandai tidak-diprobe); pilihan model dari hasil live discovery (cap 10) atau manual dengan default preset; (3) rekomendasi mode keamanan (auto untuk mock/Ollama lokal, guided untuk cloud — dipilih via menu); `OnboardingProfile.securityMode` dirender ke `security.mode`; (4) wizard workspace (buat direktori bila setuju) + pemeriksaan dependency `git`/`ollama` via `OnboardingAssist.checkDependencies` (injektable, fail-open); (5) recovery: config invalid di awal ditawari rollback revisi terakhir (`OnboardingRecovery.verifyAndRecover` mencari revisi valid terakhir & rollback), probe gagal memberi opsi ulangi/ganti base_url/isi manual/batal, dan verifikasi pasca-tulis memulihkan otomatis bila hasil write korup; API key yang sudah ada di env dipakai tanpa ditulis ulang ke gateway.env. Modul di agent_providers + tiko_runtime sepenuhnya dites mock (13 + 7 test), wizard CLI 6 test scripted.
