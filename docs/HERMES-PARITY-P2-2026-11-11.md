# Hermes Parity P2 — Laporan Batch (2026-11-11)

**Base:** `d1fc014` (P1-7..P1-10, CI hijau) · **Delivery:** commit langsung ke `main`

Lima item backlog P2 dari laporan audit menyeluruh (§7) kini diimplementasi, diuji, dan di-wire.

## P2-11 — Gateway Signal + Matrix

| Item | Detail |
|------|--------|
| Signal | `packages/agent_gateway/lib/src/signal_gateway.dart` — JSON-RPC 2.0 over HTTP ke signal-cli daemon (`receive` polling + `send`/`sendTyping`), allowlist sender, dedup by timestamp, fail-closed (tanpa default localhost). |
| Matrix | `packages/agent_gateway/lib/src/matrix_gateway.dart` — client-server API v3: `GET /sync` long-poll + `PUT /rooms/{id}/send/m.room.message/{txn}` (txn id unik), allowlist room, dedup event id. |
| Wiring | `apps/agentd/bin/agentd.dart`: env `SIGNAL_RPC_URL`+`SIGNAL_ACCOUNT`+`SIGNAL_ALLOW`, `MATRIX_HOMESERVER`+`MATRIX_ACCESS_TOKEN`+`MATRIX_ALLOW` (pattern Telegram: env tidak lengkap = exit 1). |
| Tes | `test/signal_gateway_test.dart`, `test/matrix_gateway_test.dart` — stub HttpServer loopback: envelope→inbound, allowlist, POST/PUT diverifikasi, txn unik, sessionKey asing ditolak. |

## P2-12 — Cloud sandbox backend (Modal + Daytona)

| Item | Detail |
|------|--------|
| Enum | `SandboxKind` + `modal`, `daytona` (`packages/agent_tools/lib/src/sandbox.dart`). |
| Daytona | REST `POST {DAYTONA_API_URL}/sandbox/{id}/exec` (Bearer `DAYTONA_API_KEY`), parse defensif `exitCode|exit_code`/`stdout`/`stderr`; HTTP client injectable untuk tes. |
| Modal | CLI `modal sandbox exec <id> -- <argv>` (probe `which modal`); binary injectable untuk tes. |
| Kontrak | `startProcess()` throw `UnsupportedError` untuk cloud kinds (fail-closed — hanya `run()` yang didukung); output tetap bounded `maxOutputBytes`. |
| Dispatch | `dispatchFor()` band high-risk (≥0.7): ssh > daytona > modal > docker (backward-compatible). |
| Runtime | `TikoRuntime.create()`: `SandboxKind.none` + env `DAYTONA_SANDBOX_ID`+`DAYTONA_API_KEY` (atau `MODAL_SANDBOX_ID` + modal CLI) → upgrade ke cloud via `SandboxRunner.cloudFromEnv()`; `sandboxKind` health mencerminkan kind aktual. |
| Tes | `test/cloud_sandbox_test.dart` — stub REST (parse + 500→StateError), PATH/`modalBin` shim, startProcess ditolak, `cloudFromEnv`, assert konstruktor. |

## P2-13 — Kanban multi-process

| Item | Detail |
|------|--------|
| Board | `packages/tiko_runtime/lib/src/kanban_board.dart` — `KanbanBoard(path)` durable JSON (`{tasks: {...}}`), states `backlog|doing|done|failed`, atomic write (tmp+rename). |
| Atomisitas | Semua mutasi dalam `CrossProcessLock` (O_EXCL); `claim` hanya menang untuk satu claimer (backlog→doing). |
| Tool | `kanban` (action `add|list|claim|complete|fail|delete`) risk low; terdaftar di `TikoRuntime.create()` (`<dataDir>/kanban.json`). |
| Tes | `test/kanban_board_test.dart` — lifecycle, claim atomik dua instance (hanya satu pemenang), durability antar instance, transisi invalid ditolak, tool e2e. |

## P2-14 — MCP OAuth 2.0 client-credentials

| Item | Detail |
|------|--------|
| Klien | `packages/agent_tools/lib/src/mcp/oauth.dart` — `McpOAuthConfig` (validasi token URL/scope) + `McpOAuthClientCredentials` (fetch token, cache `expires_in`−60s, `invalidate()`). |
| Transport | `HttpMcpClient(oauth: ...)` — header `Authorization: Bearer` otomatis; HTTP 401 → invalidate + refresh + replay tepat satu kali (guard flag, tanpa loop). |
| Config | `mcp.servers[].oauth: {token_url, client_id, client_secret: "env:VAR", scopes: [...]}` — divalidasi di `tiko_config.dart` (secret wajib SecretRef); `startMcp()` resolve secret → server disabled bila env hilang. |
| Tes | `test/mcp_oauth_test.dart` — Basic auth kredensial, Bearer terkirim, cache (1 fetch), 401→refresh sekali, token URL tidak aman ditolak. |

## P2-15 — CI Android/Termux

| Job | Isi |
|-----|-----|
| `termux-eco` | Tes 4 package inti (agent_core/memory/tools/tiko_runtime) + verifikasi fallback memori JSON deterministik via `TIKO_FORCE_JSON_MEMORY=1` (env baru di `TikoRuntime.create()`, tes `test/eco_memory_backend_test.dart`). |
| `android-apk` | `flutter create --platforms=android` + `flutter build apk --debug` pada `apps/agent_flutter` (validasi kompilasi AOT Android; JDK 17 temurin). |

## Verifikasi lokal (Dart SDK 3.14.0)

- `dart analyze` strict: 0 error/warning di seluruh workspace member.
- `dart test`: agent_core 105, agent_providers 25, agent_security 55, agent_scheduler 35, agent_calc 132, agent_memory 80, agent_gateway 43, agent_tools 212, tiko_runtime 93, agentd 1 — semua lulus.
- `dart compile exe apps/agentd` lulus.
