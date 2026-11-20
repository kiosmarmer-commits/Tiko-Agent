# Tiko-Agent

Tiko-Agent adalah monorepo Dart untuk agent AI lokal-first dengan CLI, daemon HTTP/WebSocket, client Flutter, gateway multi-channel, tools, MCP, memory, scheduler, security gate, dan modul prediksi.

Dokumentasi ini membedakan kode yang tersedia, kode yang terhubung ke runtime, dan integrasi yang memerlukan secret atau software host. Source code dan test adalah sumber kebenaran perilaku.

## Mulai cepat

```sh
git clone https://github.com/kiosmarmer-commits/Tiko-Agent.git
cd Tiko-Agent
bash install.sh
dart run apps/tiko/bin/tiko.dart setup --provider mock
dart run apps/tiko/bin/tiko.dart config validate
dart run apps/tiko/bin/tiko.dart chat
```

`install.sh` memasang dependency Dart dan mengompilasi `tiko`, `agentd`, serta `agent_cli`. Instalasi ini tidak memasang Flutter, provider LLM, atau sandbox OS. Detail platform ada di [INSTALL.md](INSTALL.md).

## Peta repository

| Lokasi | Tanggung jawab | Titik masuk utama |
|---|---|---|
| `packages/agent_core` | Agent loop, context, routing, skill gate, multi-agent orchestration | `agent_loop.dart`, `agent_team.dart` |
| `packages/agent_calc` | Kalkulasi decimal deterministik dan batas input | `lib/agent_calc.dart` |
| `packages/agent_providers` | Adapter LLM/decision, capability probe, health, circuit breaker | `lib/agent_providers.dart` |
| `packages/agent_tools` | Registry, built-in tools, sandbox, browser/CDP, MCP, search, vision | `lib/agent_tools.dart` |
| `packages/agent_memory` | SQLite/JSON memory, FTS/BM25, vector index, RAG, layered memory | `lib/agent_memory.dart` |
| `packages/agent_security` | Permission, approval, redaction, audit, prompt/content guard | `lib/agent_security.dart` |
| `packages/agent_gateway` | Gateway messaging, webhook, voice, TTS/STT, smart-home provider | `lib/agent_gateway.dart` |
| `packages/agent_scheduler` | Cron, timezone/DST, job store, retry, delivery acknowledgement | `lib/agent_scheduler.dart` |
| `packages/tiko_runtime` | Composition root: config, runtime, approval, bots, plugin, self-learning | `lib/tiko_runtime.dart` |
| `packages/prediksi` | Indikator, sinyal, risiko, backtest, siklus, ensemble prediksi | `lib/prediksi.dart` |
| `packages/simpul_core` | Vault Markdown/Obsidian, index, graph, RAG, layout | `lib/simpul_core.dart` |
| `packages/tiko_tui` | Komponen terminal UI | `lib/tiko_tui.dart` |
| `apps/agentd` | Daemon gateway + HTTP/WebSocket API | `bin/agentd.dart` |
| `apps/tiko` | CLI utama dan command lokal | `bin/tiko.dart` |
| `apps/agent_cli` | CLI client untuk agentd | `bin/agent_cli.dart` |
| `apps/agent_flutter` | Client Flutter untuk API agentd | `lib/main.dart` |
| `apps/tiko_widgets` | Widget Flutter reusable dan GenUI renderer | `lib/tiko_widgets.dart` |
| `apps/simpul` | CLI vault Simpul | `bin/simpul.dart` |

## Kapabilitas

### Runtime dan reasoning

- ReAct-style agent loop dengan budget, cancellation, timeout, tool concurrency, loop guard, dan evidence ledger.
- Routing provider bertingkat dengan capability probe, health state, fallback, dan circuit breaker.
- Multi-agent DAG: registry agent, task graph, wave parallel, blackboard, cancellation, dan synthesis.
- Skills: draft, evaluate, approve, rollback, import/export `SKILL.md`, metrics, dan ledger.
- Self-learning/reflection dengan guard, score, approval, dan idle consolidation.

### Tools, MCP, dan browser

- Built-in tools untuk file, shell terjaga, kalkulasi, memory, scheduler, search, vision, image/video, sandbox, worktree, skill hub, dan subagent.
- MCP stdio dan Streamable HTTP dengan OAuth client-credentials/authorization-code, reconnect, session recovery, sampling, tools/list, dan tools/call.
- Browser CDP lokal dan backend remote Browserbase/Browser Use; router dapat fallback ke Chromium lokal.
- Search provider berlapis dengan parallel search dan fallback terukur.

### Memory dan data

- SQLite sebagai backend utama bila tersedia, JSON fallback untuk lingkungan terbatas.
- FTS/BM25, vector index, hybrid retrieval, RRF, rerank, citation context, session store, memory provider eksternal, dan memory layer episodic/semantic/procedural.
- Semua data runtime berada di `data/` dan tidak boleh masuk Git.

### Gateway dan automation

- Telegram, Discord, Slack, WhatsApp, Email, Signal, Matrix, LINE, Teams webhook, Home Assistant, dan webhook HTTP sesuai konfigurasi.
- Delivery wrapper menyediakan timeout, retry terbatas, exponential backoff, dan close forwarding.
- LINE memiliki webhook routing dan validasi HMAC signature.
- Scheduler mendukung cron, IANA timezone/DST, retry, dan acknowledgement.

### Smart home

`agent_gateway` menyediakan kontrak seragam `SmartHomeProvider` untuk Home Assistant REST/WebSocket, Tuya Cloud HMAC-SHA256, dan SONOFF/eWeLink CUBE/iHost REST/SSE. Google Home didukung melalui jalur Home Assistant: hubungkan Google Home ke Home Assistant lalu gunakan provider Home Assistant.

Provider tersebut saat ini adalah library integration surface dan test contract; wiring command/tool user-facing ke `agentd` masih merupakan pekerjaan lanjutan.

### Security

- SecretRef/environment-based secret, redaction, SSRF guard, permission gate, approval broker, audit event, prompt/content guard, kill switch, dan fail-closed sandbox policy.
- `API_TOKEN`, bot token, OAuth secret, dan provider key tidak boleh ditulis langsung ke YAML, source, README, atau test fixture.

## Dokumentasi berdasarkan urutan baca

1. [INSTALL.md](INSTALL.md) — instalasi, setup, Flutter, daemon, API, troubleshooting.
2. [docs/00-INDEX.md](docs/00-INDEX.md) — status implementasi dan peta dokumentasi.
3. [docs/01-ARSITEKTUR.md](docs/01-ARSITEKTUR.md) — aliran runtime dan composition root.
4. [docs/02-PROVIDER-AI.md](docs/02-PROVIDER-AI.md) — provider, routing, health, circuit breaker.
5. [docs/03-TOOLS-MCP-SKILLS.md](docs/03-TOOLS-MCP-SKILLS.md) — tools, MCP, sandbox, skills.
6. [docs/04-MEMORI-DB-PENCARIAN.md](docs/04-MEMORI-DB-PENCARIAN.md) — memory dan retrieval.
7. [docs/05-SCHEDULER-BOT-GATEWAY.md](docs/05-SCHEDULER-BOT-GATEWAY.md) — scheduler, bot, channel.
8. [docs/06-AGENT-ALGORITMA-SELFLEARNING.md](docs/06-AGENT-ALGORITMA-SELFLEARNING.md) — loop, evaluasi, self-learning.
9. [docs/07-KEAMANAN-OBSERVABILITAS.md](docs/07-KEAMANAN-OBSERVABILITAS.md) — threat model dan observability.
10. [docs/08-PEDOMAN-PENGEMBANGAN.md](docs/08-PEDOMAN-PENGEMBANGAN.md) — aturan menambah modul, fitur, algoritma.
11. [docs/HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md](docs/HERMES-TOOLS-GAP-ANALYSIS-2026-11-20.md) — analisis parity Hermes; snapshot, bukan kontrak runtime.

## Validasi lokal

```sh
dart pub get
dart analyze --fatal-warnings
dart test
bash scripts/validate.sh
```

Untuk area tertentu:

```sh
dart test packages/agent_tools/test
dart test packages/agent_gateway/test
dart test packages/tiko_runtime/test
flutter analyze apps/agent_flutter
flutter test apps/agent_flutter/test
```

CI juga menjalankan shell/Python validation, strict analysis setiap workspace member, test Dart, random-order test, CLI/setup smoke, installer smoke, daemon lifecycle, dan validasi/build Flutter. Status terbaru harus dibaca dari GitHub Actions.

## Aturan perubahan singkat

Sebelum coding, tentukan package pemilik, kontrak publik, state/data yang berubah, security boundary, dan acceptance test. Tambahkan test isolasi untuk perilaku baru, jalankan analyzer + test package terkait, lalu perbarui dokumentasi dan status. Baca [pedoman pengembangan](docs/08-PEDOMAN-PENGEMBANGAN.md) sebelum mengubah loop agent, memory, routing, security, gateway, atau algoritma prediksi.

## Lisensi

Lihat [LICENSE](LICENSE).
