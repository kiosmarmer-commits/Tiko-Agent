# Fase D — Tugas Terjadwal & Riset Otomatis (dengan papan Kanban)

Dokumen desain + referensi riset untuk Fase D: riset otomatis berkalender
yang digerakkan scheduler Tiko dan terlihat sebagai kartu di papan Kanban.

## 1. Referensi fitur serupa (riset 2026-11)

| Agent | Fitur | Yang diadaptasi | Yang sengaja tidak diadopsi |
| --- | --- | --- | --- |
| **Hermes Agent** (Nous Research) | Cron job menempel di runtime — gateway daemon tick tiap 60s, tiap job di sesi agent terisolasi, output dikirim via gateway (Telegram/Slack/Email); dipakai untuk "research digests" harian | Konsep job = prompt self-contained + jadwal + channel tujuan; run di sesi terisolasi; delivery + retry | `context_from` chaining antar-job (kontrak JobStore Tiko belum berantai); CLI cron "every 1h" (Tiko tetap 5-field cron) |
| **ChatGPT Tasks / Pulse** | Tugas terjadwal berbasis prompt; Pulse riset proaktif harian → digest | UX user: user hanya memberi pertanyaan + jadwal, TANPA memilih model/tool | Cloud-scheduler vendor (Tiko self-host) |
| **OpenClaw** | HEARTBEAT.md — "papan" tugas berulang sebagai file plain-text yang bisa dibaca/di-commit | Filosofi state readable: kita pakai papan Kanban `data/kanban.json` yang sudah durable + cross-process lock | HEARTBEAT polling loop |
| **GPT-Researcher / OpenAI Deep Research** | Pipeline multi-tahap: plan → parallel sub-researchers → synthesize (laporan bersumber) → critique/verify | Bentuk pipeline 4 tahap + laporan markdown dengan bagian Ringkasan/Temuan/Kesimpulan/Sumber + catatan review | Iterasi refine multi-putaran & scraping penuh (budget guard Tiko batasi) |

Simpulan desain: riset Tiko harus **job scheduler** (durable, retry, delivery
ack — bukan loop in-process), tapi **state-nya harus terlihat** — papan Kanban
yang sudah ada dipakai sebagai representasi visual melalui kartu riset.

## 2. Arsitektur

```
tiko research "…" / POST /v1/research/run / tool deep_research           → run sekarang
tiko research schedule "…" --cron … / tool schedule_research             → job ber-prefix [RISET]
                                │
                                ▼
   JobStore (durable, missed_policy, delivery ack, retry backoff)
                                │ tick scheduler
                                ▼
   TikoRuntime.runResearch  ──►  ResearchKanbanTracker  ──► data/kanban.json
        │   (card: backlog → doing → done/failed, note = digest)
        ▼
   ResearchRunner (tahap murni, injected turns)
   1. plan       planner tanpa tool → {"queries":[...]}  (fail-closed → pertanyaan asli)
   2. gather     sub-riset paralel (maxConcurrency 1..4),
                 tool allowlist: web_search, web_fetch, http_request,
                 read_file, list_dir, grep, unzip_archive, datetime
   3. synthesis  laporan markdown bersumber (Ringkasan/Temuan/
                 Kesimpulan/Sumber)
   4. review     critic; catatan ditempel di bagian "Catatan Review"
        │
        ▼
   ResearchRunStore — data/research/index.json + reports/riset-<id>.md
                                │
                                ▼
   digest (summary + jalur laporan) → delivery gateway channel milik job
```

## 3. Komponen

- `packages/tiko_runtime/lib/src/research.dart` — semua Fase D:
  - `ResearchRunRecord`, `ResearchRunStore` (indeks atomik, laporan markdown,
    traversal-ditolak, indeks korup dilompati — pola `BotTeamStore`);
  - `parseResearchPlan` (JSON murni/code fence/prose, dedupe, maks 6 query);
  - `ResearchRunner` — pipeline murni (injected turns), event
    `research.started|planned|gather_started|gather_done|gather_failed|
    plan_fallback|review_failed|finished`;
  - `ResearchKanbanTracker` — cerminkan state ke `KanbanBoard`;
  - tool `deep_research` (medium risk) & `schedule_research` (medium risk).
- `packages/tiko_runtime/lib/src/tiko_runtime.dart` — `ResearchRunStore` di
  constructor; handler scheduler mendeteksi prefix `[RISET]` pada prompt job
  dan menjalankan pipeline riset alih-alih turn chat biasa (sukses tetap
  lewat `recordSuccess` + `awaitDelivery`).
- REST (`packages/agent_gateway`): `GET /v1/research/runs`,
  `GET /v1/research/runs/<id>` (run + laporan), `POST /v1/research/run`
  (`question`, `max_concurrency` 1..4); runner belum dikonfigurasi → 501.
- CLI (`apps/tiko`): `tiko research "<pertanyaan>" [--concurrency N]`,
  `research runs`, `research show <id>`, `research jobs`,
  `research schedule "<pertanyaan>" --cron "0 8 * * *" [--tz Zona]`.
- agentd menyambungkan callback REST → runtime.

## 4. Integrasi Kanban (kenapa digabung di sini, bukan sistem lain)

`data/kanban.json` sudah durable, lintas-proses (CLI ↔ daemon ↔ GUI), dan
sudah ditampilkan di TUI (`tiko` Tasks) + Flutter web (Tasks view). Kartu
riset:

- dibuat per run dengan judul `Riset: <pertanyaan>` (dipotong 80 char),
  dibuat `backlog` dan langsung `doing` saat pipeline jalan;
- `done` dengan result = digest (atau jalur laporan bila digest kosong);
- `failed` dengan error bila pipeline gagal;
- job terjadwal menghasilkan kartu per tick — riwayat riset harian terbaca
  dari papan tanpa membuka log.

Operasi papan bersifat best-effort: kegagalan filesystem/lock tidak pernah
menggagalkan riset (event `research.kanban_error`).

## 5. Uji

- `packages/tiko_runtime/test/research_test.dart` (16 test): parser rencana,
  pipeline (paralel, fallback, catatan review, sintesis gagal), store
  roundtrip/korup/traversal, lifecycle kanban, deteksi prefix, kedua tool.
- `packages/agent_gateway/test/http_api_research_test.dart`: seluruh route
  `/v1/research/*` + validasi + 501.
- `packages/agent_scheduler` & `packages/agent_gateway` full suite lulus.
