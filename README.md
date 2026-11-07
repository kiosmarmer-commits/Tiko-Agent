# agent_dart

Agent AI otonom berbahasa Dart yang meniru kemampuan inti [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research): tool calling, memori persisten, skill, scheduler, gateway multi-platform, dan integrasi MCP.

**Status:** M0 + M1 (fondasi + OpenAI-compat + tools + PermissionGate).

Dokumen rancangan lengkap ada di folder `docs/` (AGD-00 … AGD-09).

## Prinsip desain

| ID | Prinsip |
|----|---------|
| P-01 | Provider-agnostic |
| P-02 | Local-first |
| P-03 | Default-deny untuk tool berisiko |
| P-04 | Semua tool call dan keputusan dicatat (audit) |
| P-05 | Bertahap — setiap fase menghasilkan sistem yang bisa dipakai |
| P-06 | Kapabilitas dideteksi, tidak diasumsikan |

## Struktur monorepo

```
agent_dart/
├─ packages/
│  ├─ agent_core/          # loop, interface, konteks (pure Dart)
│  ├─ agent_providers/     # mock + OpenAI-compat
│  ├─ agent_tools/         # registry, builtin, script runner
│  ├─ agent_memory/        # drift + FTS5 (M2)
│  ├─ agent_gateway/       # Telegram dll (M4)
│  ├─ agent_scheduler/
│  └─ agent_security/      # PermissionGate
├─ apps/
│  ├─ agentd/              # daemon
│  ├─ agent_cli/           # CLI interaktif ✅
│  └─ agent_flutter/
├─ config/agent.yaml
├─ tools/echo_demo/        # contoh script tool
├─ skills/
└─ docs/
```

## Cara jalanin (M0–M1)

```bash
# Butuh Dart SDK ≥ 3.8
cd agent_dart
dart pub get

# Unit tests
dart test packages/agent_core
dart test packages/agent_tools
dart test packages/agent_security

# CLI interaktif — mock (tanpa Ollama)
dart run apps/agent_cli/bin/agent_cli.dart

# CLI + Ollama lokal
# ollama pull qwen2.5:3b
AGENT_PROVIDER=ollama OLLAMA_MODEL=qwen2.5:3b dart run apps/agent_cli/bin/agent_cli.dart
```

Perintah CLI: `/tools` `/status` `/new` `/quit`

Contoh:
- `Halo` → jawaban teks
- `berapa waktu sekarang?` → tool `datetime`
- `hitung (2+3)*4` → tool `calc`

## Yang sudah ada di M1

| Komponen | File | Status |
|----------|------|--------|
| OpenAI-compat streaming + tool call | `agent_providers/.../openai_compat.dart` | ✅ |
| ToolRegistry + validasi JSON Schema | `agent_tools/.../registry.dart` | ✅ |
| Builtin: datetime, calc, list_dir, read_file | `agent_tools/.../builtin.dart` | ✅ |
| Script tool runner (stdin JSON) | `agent_tools/.../script_runner.dart` | ✅ |
| PermissionGate matriks risiko | `agent_security/.../permission_gate.dart` | ✅ |
| CLI + konfirmasi interaktif | `apps/agent_cli` | ✅ |
| Contoh script tool | `tools/echo_demo/` | ✅ |

**Belum (sisa M1 / M3):** `web_fetch` + SSRF guard, `shell` tool penuh, circuit breaker.

## Roadmap

| Fase | Tujuan | Status |
|------|--------|--------|
| **M0** | Workspace, interface, loop + mock | ✅ |
| **M1** | OpenAI-compat, tools lengkap, PermissionGate, CLI, circuit breaker | ✅ |
| **M2** | Memori in-memory + VectorIndex + schema SQL (drift menyusul) | ✅ fondasi |
| **M3** | web_search (SearXNG) + MCP stdio client + mock server | ✅ |
| **M4** | Telegram long-poll + scheduler + schedule_job | ✅ |
| **M5** | DecisionProvider + router bertingkat + eval ID 50 | ✅ |
| **M6** | Skills lifecycle, subagent, feedback, golden harness | ✅ |
| **M7** | HTTP/WS API, audit, kill switch, SEC suite, client stub | ✅ |
| **M3** | SearXNG + MCP stdio | |
| **M4** | Telegram + scheduler | |
| **M5** | DecisionProvider (Laya/Jev) | |
| **M6** | Self-learning skill | |
| **M7** | Flutter + hardening | |

## Dependensi (verifikasi 2026-11-04)

| Paket | Versi | Status |
|-------|-------|--------|
| openai_dart (referensi) | 11.0.1 | ✅ — kita pakai thin `http` client dulu |
| ollama_dart | 4.0.0 | ✅ opsional nanti |
| drift | 2.35.3 | M2 |
| televerse | 3.6.0 | M4 |
| http | ^1.2.2 | ✅ dipakai OpenAI-compat |

Jalankan `python3 scripts/verify_deps.py` sebelum menambah dependensi produksi.

## Lisensi

MIT (rencana). Kode masih pra-rilis.


## M4 — Daemon, Telegram, Scheduler

```bash
# CLI + scheduler
dart run apps/agentd/bin/agentd.dart

# Telegram (numeric user id dari @userinfobot)
export TG_TOKEN=123:ABC
export TG_ALLOW=987654321
dart run apps/agentd/bin/agentd.dart --telegram

# Opsional Ollama
AGENT_PROVIDER=ollama OLLAMA_MODEL=qwen2.5:3b dart run apps/agentd/bin/agentd.dart --telegram
```

Tools jadwal: `schedule_job`, `list_jobs`, `cancel_job`  
Konfirmasi tool berisiko di Telegram lewat tombol inline (timeout 120 dtk).


## M5 — Decision & routing

```bash
# Heuristic (default, offline)
dart run apps/agentd/bin/agentd.dart

# Laya local (laya-serve)
export LAYA_URL=http://127.0.0.1:8000
dart run apps/agentd/bin/agentd.dart

# Jev hosted
export JEV_API_KEY=...
export JEV_BASE=https://api.typesafe.ai
dart run apps/agentd/bin/agentd.dart

# Eval baseline
dart test packages/agent_providers/test/decision_eval_test.dart
```

Set evaluasi: `test/eval/router_id_50.yaml` (50 kalimat Indonesia).
Guardrail: `risk=critical` → ditolak sebelum tool loop.


## M6 — Self-learning

- Skills: `skills/<slug>/SKILL.md` (frontmatter + langkah)
- Status: `draft` → `trial` → `approved` → `retired`
- Validator menolak secret / `curl|sh` / tool asing
- Feedback CLI: `/good ...` `/bad ...` → few-shot dinamis
- Subagent: tool `spawn_subagent` (kedalaman maks 2)
- Golden: `test/golden/*.yaml` + `GoldenHarness`

```bash
dart test packages/agent_core/test/skills_test.dart
dart run apps/agentd/bin/agentd.dart
# /skills
```


## M7 — API, keamanan, klien

```bash
# API lokal (bind 127.0.0.1); daemon membuat token acak dan menyimpannya
dart run apps/agentd/bin/agentd.dart --api

# Token disimpan pada data/api.token (permission POSIX 0600), bukan dicetak
# ke daemon.log. Ambil ke variabel shell tanpa menampilkannya di terminal.
TOKEN="$(tr -d '\r\n' < data/api.token)"
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/v1/status
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"text":"Halo"}' http://127.0.0.1:8787/v1/messages

# Approval pada daemon aktif menggunakan API yang sama (bukan ledger lokal baru)
dart run apps/tiko/bin/tiko.dart approvals
dart run apps/tiko/bin/tiko.dart approve apr_ID
# atau: tiko deny apr_ID
# Lifecycle stop memakai endpoint shutdown terautentikasi (tanpa kill PID mentah)
tiko daemon stop

# Safe mode adalah default; tool di luar allowlist memerlukan approval.
# --no-safe melonggarkan allowlist, bukan menonaktifkan risk gate.
dart run apps/agentd/bin/agentd.dart --api --no-safe

# Tes keamanan
dart test packages/agent_security
```

Audit: `logs/audit-YYYYMMDD.jsonl`  
CLI: `/stop` `/safe` `/unsafe` `/panic` `/unpanic`  
Klien: `apps/agent_flutter/lib/agent_api_client.dart`


## Melengkapi gap (post-M7)

- **Persistensi**: `PersistentMemoryStore` → `data/facts.json` + `data/messages/*.jsonl`
- **Config**: `AppConfig.load('config/agent.yaml')`
- **Tools**: `memory_search`, `memory_add`, `http_request` (allowlist domain + SSRF)
- **Taint**: session tertandai setelah web/MCP/http → tool medium+ wajib konfirmasi
- **Subagent**: runner nyata (nested AgentLoop, budget terpisah, depth ≤2)
- **Skill auto-draft**: jika ≥4 tool call dalam satu turn
- **Metrics**: di `/v1/status` → `metrics`
- **Stop**: `shouldStop` di loop + CLI `/stop`


## Update lanjutan (gap filling)

| Fitur | Detail |
|-------|--------|
| web_search pipeline | Top-N fetch + strip HTML + sitasi + cache TTL 1 jam |
| Compactor LLM | `Compactor(llm: ...)` ringkas via model |
| plan_task | Tool rencana bernomor (ALG-02) |
| Reflection | `AGENT_REFLECT=1` → Reflector setelah jawaban |
| MCP HTTP | `HttpMcpClient` JSON-RPC POST |
| Jobs persist | `data/jobs.json` |
| Discord | `DISCORD_WEBHOOK` outbound |
| Flutter | `ChatController` + API client |

```bash
AGENT_REFLECT=1 dart run apps/agentd/bin/agentd.dart
DISCORD_WEBHOOK=https://discord.com/api/webhooks/... dart run apps/agentd/bin/agentd.dart
```


## Update berikutnya

| Fitur | Cara |
|-------|------|
| Plan→execute | Chat: `rencanakan ...` atau CLI `/plan ...` |
| FTS memori | `data/fts.json` inverted index |
| Shell jail | CWD workspace, tolak `..` & path absolut di luar root, env minimal |
| Email | `EMAIL_FROM`, `SMTP_HOST`, `SMTP_PORT`, `EMAIL_ALLOW`, `EMAIL_TO` |
| Flutter UI | `apps/agent_flutter` — baca `data/api.token` ke variabel `TOKEN`, lalu `flutter run --dart-define=API_TOKEN="$TOKEN"` |

Masih opsional / belum: sqlite-vec native, Discord WS penuh, Docker/bubblewrap, Drift codegen.


## Kelengkapan akhir

| Komponen | Status |
|----------|--------|
| SQLite + FTS5 | `SqliteMemoryStore.tryOpen` → fallback file |
| Discord Bot WS | `DISCORD_BOT_TOKEN` + intents MESSAGE_CONTENT |
| Sandbox | auto-detect `bwrap` / `docker` / none |
| Trajectory JSONL | `data/trajectories/traj-*.jsonl` |
| Flutter UI | `apps/agent_flutter` |
| Email | SMTP relay (lihat `docs/email-smtp.md`) |

```bash
# SQLite path default: data/agent.db
# Discord bot
DISCORD_BOT_TOKEN=... DISCORD_ALLOW=userId dart run apps/agentd/bin/agentd.dart

# Sandbox: install bubblewrap or docker for isolation
```


## UI (user baru)

### Web (paling mudah — tanpa Flutter)

```bash
dart run apps/agentd/bin/agentd.dart --api
# Buka browser: http://127.0.0.1:8787/
# Token API berada di data/api.token; masukkan nilainya pada halaman Settings.
```

Tab: **Chat · Memori · Status · Bantuan · Approvals · Sessions**. Token dibuat acak oleh daemon dan tidak memiliki nilai default yang diketahui.

### Flutter

```bash
cd apps/agent_flutter
TOKEN="$(tr -d '\r\n' < ../../data/api.token)"
flutter run --dart-define=API_TOKEN="$TOKEN"
```

## Fitur baru putaran ini

- Tool calls **paralel** dalam satu putaran model
- **Self-consistency** (`SelfConsistency`)
- **Ollama embeddings** (`OLLAMA_EMBED=1`)
- Skill **feedback promote** (`applyFeedback`)
- Web UI minimalis di root API


## Kelengkapan lanjutan (full pass)

| Item | Status |
|------|--------|
| patch_file | ✅ |
| Session lock 1 task/sesi | ✅ |
| TraceContext | ✅ |
| Self-consistency (env) | ✅ `AGENT_SELF_CONSISTENCY=1` |
| Auto-reflect tool-heavy | ✅ `AGENT_AUTO_REFLECT_TOOLS=3` |
| Capability probe | ✅ `AGENT_PROBE=1` |
| Memory archive 180d | ✅ |
| SecretStore lokal | ✅ |
| Telegram split pesan | ✅ |
| Docker SearXNG | ✅ `deploy/docker-compose.yml` |
| Scripts Termux/CI/compile | ✅ `scripts/` |

```bash
./scripts/run_agentd.sh
./scripts/ci_test.sh
./scripts/compile_release.sh
```


## Item 1–7 (implementasi penuh di kode)

| # | Fitur | Cara aktifkan |
|---|--------|----------------|
| 1 | Drift-style migrasi SQLite v1–v3 | otomatis di `SqliteMemoryStore` |
| 2 | sqlite-vec | `SQLITE_VEC_PATH=/path/to/vec` + fallback embeddings table |
| 3 | STARTTLS email | `SMTP_STARTTLS=1 SMTP_USER=… SMTP_PASS=…` |
| 4 | STT Telegram | `WHISPER_BIN=whisper` atau `STT_API_KEY=…` |
| 5 | Discord slash `/ask` | `DISCORD_BOT_TOKEN` + `DISCORD_APP_ID` |
| 6 | Ollama native | `OLLAMA_NATIVE=1` atau `AGENT_PROVIDER=ollama_native` |
| 7 | Isolate pool | `IsolatePool` / `ParallelSubagentRunner` di core |

```bash
# contoh
OLLAMA_NATIVE=1 SMTP_STARTTLS=1 STT_API_KEY=sk-... \
DISCORD_BOT_TOKEN=... DISCORD_APP_ID=... \
dart run apps/agentd/bin/agentd.dart --api --telegram
```

## P1 implementation tranche (2026-11-07)

- Runtime memory retrieval is now wired into the shared context builder and retrieved content is explicitly marked as untrusted data.
- Runtime loads the workspace `skills/` directory and shares one SkillRegistry with ContextBuilder and AgentLoop.
- See `P1-IMPLEMENTATION-REPORT.md` for verified scope, static checks, and remaining P1 work.
