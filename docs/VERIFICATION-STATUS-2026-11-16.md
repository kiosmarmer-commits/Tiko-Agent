# Verification Status — 16 November 2026

Purpose: separate **what is proven** from **what is claimed** in this repository.

## 1. Snapshot

| Item | Value |
|---|---|
| Branch | `main` |
| Commit | `99ff1484d9` |
| CI run on `main` | `43716634190` — success |
| Latest branch run | `vibe/p1-hardening-followup` #395 — success (2026-11-15T17:13Z) |
| Total recorded runs | 409 |

## 2. What CI verifies

`ci.yml` triggers on `push`, `pull_request`, and a weekly cron. The `dart` job:

- pins Dart `3.13.4` via `dart-lang/setup-dart@v1`
- runs `bash scripts/web_ui_validate.sh`
- `bash -n` on `scripts/*.sh`, plus `python3 -m compileall`
- `dart pub get`
- strict analysis (`dart analyze --fatal-warnings`) across `packages/*`,
  `apps/agentd`, `apps/tiko`, `apps/agent_cli`, `apps/simpul`
- `dart test --reporter json` for every workspace member that has `test/`

CodeQL additionally analyses python, javascript-typescript and actions.

## 3. What CI does NOT verify

The workflow's own comment states it uses *"loopback e2e mocks: MCP, gateways,
LLM API"*. A green run therefore says nothing about:

- Discord voice cryptographic correctness against a live gateway
- real Telegram / Discord / Slack / WhatsApp / Email credentials and delivery
- third-party MCP server compatibility
- OS sandbox behaviour on hosts without bubblewrap/Docker (Termux/proot is not
  an isolation boundary)
- vector retrieval quality and latency at scale (no benchmark exists)

## 4. Audit findings re-verified by reading source at this snapshot

| Finding (`REPOSITORY-AUDIT-2026-11-09.md` §4) | Result | Evidence |
|---|---|---|
| Email gateway accepts invalid certificates | Closed | `email_gateway.dart`: `SecureSocket.secure(socket, host: host)`, no `onBadCertificate`, plaintext downgrade refused |
| IMAP `onBadCertificate` | Not a defect | `imap_client.dart`: `(_) => false` |
| Flutter returns `{}`/`[]` on HTTP error | Closed | `_throwIf(res, ...)` in all five read endpoints |
| `deleteMemory(id)` unencoded | Closed | `Uri.encodeComponent(id)` |
| `streamChat()` token in query | Closed, stronger | one-shot ticket via `_requestStreamTicket`, `Uri.replace(queryParameters: ...)` |

Other §4 items were **not** re-verified here; do not assume their status.

## 5. Regression guards

`packages/agent_security/test/regression_guard_test.dart` locks the closed findings:

1. no production TLS client accepts invalid certificates
2. Flutter path identifiers are percent-encoded
3. Flutter stream uses a ticket, never a raw token in the query
4. Flutter read endpoints surface HTTP errors

The scan covers only `lib/` and `bin/`, so test fixtures cannot trip it.

## 6. Reporting rule going forward

Replace single-percentage parity claims with a three-level status:

| Level | Meaning |
|---|---|
| `unit-tested` | module has tests; may not be reachable from the runtime |
| `wired` | reachable from runtime/daemon/CLI |
| `verified-e2e` | exercised against the real external dependency |

Count a feature as delivered only at `verified-e2e`.
