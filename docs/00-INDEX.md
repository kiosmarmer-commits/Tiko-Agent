# Indeks Dokumentasi Tiko-Agent

**Source snapshot:** commit `b9ff9d7` pada branch `main` (merge PR #223; status merge lihat GitHub).

**Terakhir diperbarui:** 28 November 2026.

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
| 14 | [14-A2UI-GENERATIVE-UI.md](14-A2UI-GENERATIVE-UI.md) | Fase E — A2UI generative-UI (E1–E7 terimplementasi: model/validasi, tool `render_a2ui`, bridge + store, REST, renderer chat, CLI `tiko surface*`, halaman Surface, ApprovalSheet, surface riset + DAG team run, aksi `open_url` allowlist host) |
| 15 | [15-ROADMAP-SETARA-AI-AGENT.md](15-ROADMAP-SETARA-AI-AGENT.md) | Roadmap setara/unggul vs AI agent lain (F1–F10 selesai; prinsip additive, status per fase) |
| 16 | [16-AUDIT-RESPONSIVE-ACCESSIBILITY.md](16-AUDIT-RESPONSIVE-ACCESSIBILITY.md) | Snapshot audit responsive/accessibility historis; checklist perangkat yang belum diverifikasi tetap berguna |
| 17 | [17-AUDIT-GUI-CLI-UX-2026-11-26.md](17-AUDIT-GUI-CLI-UX-2026-11-26.md) | Catatan terbaru perbaikan GUI/CLI PR #199, kontrak JSON, status verifikasi, dan klaim lama yang usang |
| 18 | [18-AUDIT-PAPER-2026-11-28.md](18-AUDIT-PAPER-2026-11-28.md) | Implementasi audit riset paper 2026-11-28 (RAG-01 rehidrasi, Self-RAG gate, RAG-02 cache vektor, EVAL-01 benchmark, LEARN-01 feedback loop, ToT/LATS `deep_solve`, API-Bank schema + EVAL-02 skill benchmark, RAPTOR-lite, GraphRAG-lite) dan daftar item yang di-defer |

## Status implementasi

| Area | Status | Batasan penting |
|---|---|---|
| Agent loop, cancellation, budget, tool orchestration | Implemented | Perubahan harus menjaga contract test agent_core |
| Provider AI, routing, health, circuit breaker | Implemented/conditional | Memerlukan endpoint dan secret provider |
| Memory SQLite/JSON, FTS, vector, RAG, layers | Implemented/conditional | SQLite native tidak selalu tersedia; JSON fallback degraded |
| Tools, sandbox, MCP stdio/HTTP, OAuth | Implemented/conditional | Sandbox OS dan secret dapat membuat capability unavailable; opsi opt-in `sandbox.allow_host_exec` (default false) menjalankan `shell` tanpa interpreter bila sandbox OS tidak ada (F1) |
| Browser CDP lokal/remote | Implemented/conditional | Chrome atau backend remote harus tersedia |
| Scheduler dan job delivery | Implemented | Channel tujuan harus aktif |
| Telegram/Discord/Slack/WhatsApp/Email/Signal/Matrix/LINE | Implemented/conditional | Masing-masing membutuhkan konfigurasi dan credential |
| Teams | Implemented | Outbound webhook dan inbound Bot Framework activity melalui `/webhooks/teams` dengan bearer token |
| ACP resources | Implemented | List/read/write resource terdaftar, resource read-only, dan command fail-closed |
| Wake-word Porcupine/openWakeWord | Implemented (bridge) | Detector eksternal apa pun via `SubprocessHotwordListener` (`wake_word.command`); fallback energy/keyword tetap; binding native Porcupine (butuh binding binary) tidak ditautkan |
| Event Hooks (Hermes-parity P1) | Implemented | Config `hooks:` (event/webhook/script); hasil di `hook.executed` + snapshot `/v1/plugins`; GUI Settings > Hooks (`hooks_view.dart`) lengkap (list/tambah/edit/uji/statistik) |
| Cron pause/resume + attach skill + [CRON_FAILURE] (Hermes-parity P2) | Implemented | Endpoint pause/resume + PATCH `paused`/`skill`; status run (`last_status`, `failure_streak`) di `/v1/jobs` |
| @ Context references @file/@folder/@git-diff/@url (Hermes-parity P3) | Implemented | Ekspansi fail-closed di `chatWithStatus` (command `/` dan code fence dikecualikan); event `context.expanded`; chip + autocomplete `@file/@folder/@url/@git-diff` di composer web (`context_ref_suggest.dart`) |
| Endpoint OpenAI-compat `/v1/chat/completions` (Hermes-parity P4) | Implemented | Non-stream + SSE (single-delta + `[DONE]`); system/transcript/user-terakhir; error shape OpenAI; auth `/v1` sama; usage estimasi len/4 |
| Tiko sebagai MCP Server (stdio) | Implemented | `tiko mcp` — `McpAgent` JSON-RPC 2.0 stdio; tools `tiko_chat` (turn penuh + gate fail-closed), `tiko_cancel`, `tiko_tools`, `tiko_sessions`, `tiko_status`; sesi `mcp:*` terpisah; hanya stdio, tanpa streaming |
| Markdown + tombol salin di chat (Chat-UX C1) | Implemented | `TikoMarkdownView` subset markdown + code block tersalin sendiri; tombol Salin per-pesan asisten; tanpa dependency baru; bukan CommonMark penuh |
| Lampiran file end-to-end (Chat-UX C2) | Implemented | Inline base64 di `POST /v1/messages` + WS (maks 4 file, 2 MiB, mime allowlist, fail-closed); runtime ingest `[lampiran:]` (Fase A superset) 64 KiB/file 128 KiB total; gambar kini diteruskan ke provider vision (Fase A.4); picker Web via `dart:html`, desktop → `@file:` |
| Embedded file view + kartu diff di chat (Chat-UX C3) | Implemented | `ChatArtifactPanel` di kanan chat (≥1100px) / overlay mobile; chip `@file:` di pesan; kartu file + Lihat/Diff vs `.bak`; filter per-sesi bertahap (chip `@file:` pesan + korelasi `createdAt` sesi, dropdown filter halaman Artifacts, publish/share `/v1/artifacts/publish`); sumber otomatis kartu dari tool trace C4 (`chat.tool` -> `lastTurnTrace` -> `messages.files` saat frame `done`) |
| Status proses turn + tombol Stop (Chat-UX C4) | Implemented | WS frames `chat.status`/`chat.toolStart`/`chat.tool` (args tersanitasi, hanya `path` tool file); strip spinner + tool aktif; ringkasan collapsible N tool + durasi + error; Stop kooperatif via `rt.cancelTurn` (frame `cancel`/`cancel_ack`); `POST /v1/messages` kini juga mendukung SSE live (frame status/tool/delta sama dengan WS) — docs/12 item 9 |
| Batch processing + trajektori export (Hermes-parity P5) | Implemented | `tiko batch run --tasks JSONL --concurrency 1..16` (chatWithStatus + TrajectoryLogger + laporan `data/batch/`); `tiko batch export --out` JSONL/ShareGPT, redaksi secret default |
| A2UI generative-UI (Fase E) | Implemented (E1–E9) | Model pesan + validator fail-closed (`agent_core/agent_a2ui.dart`), tool `render_a2ui`, `A2uiToolBridge` + `SurfaceStore` + event `surface.*`, REST `/v1/surfaces*`, renderer chat `TikoSurfaceOrMessageView` (termasuk skeleton streaming fence yang belum tertutup), CLI `tiko surface*` (`remote_client.dart` + `bin/tiko.dart`), halaman Surface (`ui/surfaces_view.dart` + `A2uiSurfaceRecordView`), katalog chart bar|line|area|donut, komponen `ApprovalSheet` (risiko + perintah + chip risiko), surface ringkasan dari research-run (`a2ui_research.dart`), DAG view run team di halaman Runs (`runs_page.dart`), aksi `open_url` pada Button A2UI yang dimediasi allowlist host `a2ui.open_url_allow` (`A2uiOpenUrlPolicy`, default kosong = fail-closed), form input dua arah (E6): input → `a2ui_input` → tulis-balik `@path` + aksi `onChanged` repeatable, komponen `List` + `Tabs` (E7), komponen `Modal` host-mediated (E8). E9 (S18) menambah komponen `Video`/`AudioPlayer` (embed web asli, placeholder jujur non-web) dan chart `pie`/`scatter`/`hbar` |
| Project context file TIKO.md/AGENTS.md/CLAUDE.md/GEMINI.md (Fase A.1) | Implemented | `resolveProjectContextFile` + CLI `tiko context`; disuntik ke system prompt tiap turn (prioritas TIKO.md > AGENTS.md > CLAUDE.md > GEMINI.md); cap 12.000 char penanda jujur; fail-closed |
| Zip auto-extract saat attach (Fase A.2) | Implemented | `ingestAttachments` ekstrak zip ke `data/uploads/<sesi>/` (anti traversal/absolut, 500 entry, 16 MiB/entry, 64 MiB total) + tool `unzip_archive` untuk turn agent; listing teratas inline; fail-closed |
| Ekstraksi teks dokumen PDF/DOCX/ODT/XLSX/PPTX (Fase A.3) | Implemented | `extractDocumentText` pure-Dart best-effort (`doc_extract.dart`, paket `archive`); file mentah juga disimpan ke uploads sebagai path referensi; budget 64 KiB/file; semua gagal → catatan juhur (“fail-closed”) |
| Vision/multimodal image input (Fase A.4) | Implemented (provider-level) | `ChatImage` di `ChatMessage` dikirim ke openai_compat/azure (image_url), anthropic (blok image), gemini (inline_data), ollama_native (images[]), openai_responses (input_image); maks 4 gambar turn, 4 MiB/gambar; passthrough bergantung gateway mengirim bytes raw (web chat base64 → bytes) |
| Auto coding/debugging loop `tiko fix` + tool `verify_project` (Fase B) | Implemented | `CodeLoopRunner` (tiko_runtime): turn agent (tool write/patch difilter) → exit 0 adalah gate sukses, bukan klaim model → umpan balik output-ke gagal ke turn berikut; maks 8 iterasi (clamp); checkpoint .tiko/checkpoints sebelum edit + jalur rollback; verifikasi argv-exec tanpa shell bila tidak ada OS sandbox; `tiko fix "<tugas>" --verify "<cmd>"` |
| Orkestra bot team satu panggilan `tiko team` + tool `bot_team` (Fase C) | Implemented | `BotTeamRunner` (tiko_runtime): planner mendekomposisi tujuan → JSON DAG tervalidasi (fallback 1 node fail-closed) → DAG dieksekusi paralel per-wave (maks 8 konkurensi, 12 node) → sintesis summarizer (gabungan deterministik bila tidak ada) → review critic → gate `--verify` opsional + turn perbaikan terbatas (mewarisi kontrak exit-0 Fase B); tim tersimpan di `data/teams/<id>.json`, laporan run di `data/teams/runs/`; event `team.*` ke EventBus/`/v1/stream`; REST `/v1/teams` (list/get/save/PUT/DELETE/run/laporan, 501 bila host tak konfigurasi); CLI `tiko team list|show|save|delete|run` |
| Home Assistant / Tuya / SONOFF eWeLink CUBE | Implemented | `SmartHomeTool.fromEnvironment` memuat ketiga provider dari env dan didaftarkan sebagai tool `smart_home` di runtime (F6.1) |
| Google Home | Conditional via Home Assistant | Tidak ada direct Google Home API provider di repo |
| Self-learning/reflection | Implemented with guards | Sintesis tetap dibatasi gate, score, dan approval |
| Flutter client/widgets | Implemented/conditional | Memerlukan Flutter SDK dan daemon/API |
| Desktop/mobile GUI accessibility & error recovery (PR #199) | Implemented (source-level) | Reduced motion, kontras foreground, semantics, target sentuh, dan retry sudah diperbaiki; verifikasi screen reader/perangkat masih belum dilakukan — lihat [audit GUI/CLI](17-AUDIT-GUI-CLI-UX-2026-11-26.md) |
| CLI JSON/recovery output (PR #199) | Implemented (source-level) | `doctor --json --fix` merupakan dry-run plan; lihat kontrak perintah dan batas stdout di [audit GUI/CLI](17-AUDIT-GUI-CLI-UX-2026-11-26.md) |
| Web dashboard agentd (Jalur A) | Implemented/conditional | Flutter Web sebagai satu-satunya webRoot + cookie sesi same-origin + auto-open browser; butuh `flutter build web` sebelum daemon dapat menyajikan UI |
| Simpul vault/index | Implemented | Modul terpisah dari agent runtime utama |
| Semantic code index + embeddings (S22) | Implemented | `code_semantic` + `tiko code-index` — hybrid BM25+cosine RRF atas indeks persisten `data/index/code-semantic.jsonl`; embedder provider `memory.embed` bila aktif, tanpa itu fallback hashing offline (dilabel jujur bukan model semantik); refresh inkremental hash sha256 per file; `code.index.enabled` default true |
| ToT/LATS bounded deep-solve — tool `deep_solve` (Fase 30) | Implemented (opt-in) | `DeepSolveEngine` (tiko_runtime): expand → LLM judge `SCORE:/REASON:` → refine per level; budget keras `max_llm_calls`/`max_wall_clock_sec`/`max_tokens_per_call`, never-raises (degenerate ke kandidat terbaik); konfigurasi `deep_solve:` default **off** karena berbiaya LLM; event telemetry `deep_solve.done` bebas-konten; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Task classifier + algorithm router — advisory `task.mode` (Fase 31) | Implemented | `TaskClassifier` heuristik deterministik (tanpa LLM): 7 mode §7.2 (fast/tool/plan/deepReasoning/research/coding/knowledge) + keyword custom via config `task_classifier:`; event `task.mode` bebas-konten + `ChatRunResult.taskMode`; advisory-only, jalur eksekusi ReAct tidak berubah; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| API-Bank task schema adapter + EVAL-02 skill benchmark (Fase 32) | Implemented | `ApiBankAdapter` (agent_core): JSONL fail-open → `EvalCase` kind `toolPrecision`; fixture mini self-authored; `SkillBenchmark` harness multi-turn + tool `skill_benchmark` dengan report persist + `regressionsVs` baseline; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| RAPTOR-lite — index hierarkis ringkasan (Fase 33) | Implemented (opt-in) | `RaptorTree` deterministik tanpa LLM (agent_memory): clustering greedy Jaccard ≥0.15 + summary ekstraktif TF, query lexical berbobot bonus level atas, save/load JSON; tool `raptor` (build/query/status) persist `data/raptor/tree.json`; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| GraphRAG-lite — graf pengetahuan + komunitas (Fase 34) | Implemented (opt-in) | `GraphRagIndex` (simpul_core): CSR + Louvain, query BFS `max_hops` decay 0.6 + scoring komunitas global, konteks `[n] source`; tool `graph_query` scan vault + build otomatis; config `graph_rag:` default **off**, `vault_dir` wajib; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Inter-agent messaging umum — group chat AutoGen-style (Fase 35) | Implemented (opt-in) | `GroupChatRunner` (tiko_runtime): transkrip bersama + speaker selection round-robin/auto (LLM, fail-open) + terminasi marker `TERMINATE` + cap `max_rounds` + sintesis summarizer; tool `group_chat`; config `group_chat:` default **off**; kontras `bot_team` (DAG paralel); lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| MemGPT-style control-flow paging (Fase 36) | Implemented | `ContextPager` (agent_memory): page-out deterministik pesan luar window → episodic (idempoten fingerprint FNV-1a, state persist bounded); page-in on-demand via tool `memory_page` (kontrol di tangan model, filter tag paged + binding sesi + overlap lexical wajib); data asli tetap utuh di session store; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| LATM maker/user tool-generation pipeline (Fase 37) | Implemented (opt-in) | `ToolMakerPipeline` (tiko_runtime): maker LLM auxiliar terpisah mendesain `ForgedToolDef` namespace `made_` → contract tests via `ToolForge` (reuse NEW-12, fail-closed) → instalasi registry; tool `tool_maker`; config `tool_maker:` default **off**; permission gate tetap berlaku; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Routines — rekam & replay langkah tool-call (Fase 38) | Implemented (opt-in) | `RoutineRecorder`/`RoutineRunner`/`RoutineStore` (tiko_runtime): langkah tool-call sukses direkam per sesi menjadi resep deterministik persist `data/routines/<id>.json`, replay fail-fast/dry-run/continue_on_error tanpa LLM; tool `routine`; config `routine:` default **off**; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| AuthorizationMemory — smart approvals dengan TTL (Fase 39) | Implemented (opt-in) | `AuthorizationMemory` (tiko_runtime): approval disetujui dicatat sebagai otorisasi (tool + hash args + scope sesi/global) ber-TTL; aksi sama berikutnya melewati approval, `never_cache_tools` selalu fail-closed; tool `authz` (list/revoke/clear); config `authorization_memory:` default **off**; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Review learnings queue — pelajaran bot wajib approve (Fase 40) | Implemented (opt-in) | `ReviewLearningsStore` + tool `review_learnings` (tiko_runtime): pelajaran hasil interaksi bot diantrikan, hanya `approve` owner yang menulis ke `BotProfile.learnings` (cap per bot) yang disuntik setelah persona; config `review_learnings:` default **off**; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Team Bot sharing & per-person permission (Fase 41) | Implemented | `BotProfile.owner`/`sharedWith`/`canUse`: bot ber-owner hanya bisa dipakai owner atau userKey yang di-share (fail-closed, backward-compatible bot lama tetap publik); `/bot share|unshare <id> <userkey>`; REST create/update bot menerima `owner`/`shared_with`; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| X/Twitter gateway — polling mentions & balasan (Fase 42) | Implemented (opt-in, daemon) | `XGateway implements Gateway` (agent_gateway): polling X API v2 `users/:id/mentions` → `InboundMessage` channel `x`, dedupe bounded + snowflake id compare, balasan POST `/2/tweets` reply `in_reply_to_tweet_id` clip 280; allowlist kosong fail-closed (drop semua) dan daemon wajib `X_BEARER_TOKEN`/`X_BOT_USER_ID`/`X_ALLOW`; env `X_POLL_SEC` opsional; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |
| Meeting notes deterministik (Fase 43) | Implemented | `MeetingNotesParser` + tool `meeting_notes` (tiko_runtime, risk low, selalu terdaftar): transkrip → notulen Markdown/JSON tanpa LLM (peserta, keputusan, tindak lanjut dengan owner inline/fallback pembicara, pertanyaan terbuka), wrap line diakumulasi ke pembicara sebelumnya, path file dijail `PathSafety`, opsional save `meetings/`; lihat [docs/18](18-AUDIT-PAPER-2026-11-28.md) |

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
