# TIKO / Agent Dart — Repair Delta 7 November 2026

## Status

This archive is a new repair snapshot based on `agent_dart_tiko_fixed_2026-11-07.zip`. It contains source changes across 20 existing files. It is **statically checked, but not Dart/Flutter build-verified**: this environment has neither `dart` nor `flutter` installed. Do not treat this snapshot as a production release until the full SDK pipeline passes.

## Repairs applied

### P0 — compile path, routing and policy

1. Implemented the missing `_loadSkill()` CLI loader. It validates the slug, limits the file size, validates the skill document, and rejects symlink/path escapes. CLI skill operations now resolve the same canonical `<workspace>/skills` directory.
2. Wrapped CLI runtime command dispatch in `try/finally` so `TikoRuntime.close()` runs when commands return or fail.
3. Enforced `RouteDecision.needTools` in `_RuntimeContext`; no-tool routes now receive an empty tool list rather than the entire registry.
4. Changed capability validation so a valid capability no longer bypasses the live permission policy. The inner policy is checked again after removing the capability field; a current denial still blocks execution.
5. Generalized `config show` secret redaction for secret-, token-, password-, credential-, private-key- and webhook-like keys.

### P1 — memory ownership, persistence and task status

6. Added owner-scoped memory retrieval. Facts and memory hits now carry `ownerKey`; ContextBuilder and `memory_search` use only the current session owner. Stores without the owner-scope contract fail closed for context retrieval.
7. Added SQLite schema migration version 6 for `facts.owner_key` plus an owner/date index. SQLite, JSON-backed, and in-memory stores filter text and vector hits by owner.
8. Enforced TTL during memory retrieval. Legacy JSON facts with a TTL but no creation timestamp are treated as expired rather than remaining forever.
9. Escaped untrusted-data envelope delimiters on the direct ContextBuilder retrieval path and memory-search tool output.
10. Fixed FileSessionStore's concurrent first-load race with a shared loading future. Writes use unique temporary names, report their own persistence errors, and redact secrets in conversation text, titles and summaries (including history loaded from older files).
11. Improved cron next-occurrence search to iterate calendar dates rather than every minute, preserving the maximum scan-window contract and supporting annual dates such as 29 February. JobStore now isolates invalid entries so one malformed/unsupported job does not discard every valid job in the file.
12. Added a structured `ChatRunResult` API while retaining the existing string-returning `chat()` API. Offline queue items are acknowledged only when AgentLoop reports success; failed turns are retried. Scheduler jobs publish `job.completed` only after the agent turn reports success.
13. AgentLoop now exposes `lastTurnSucceeded`; provider failures, denied tool calls, tool errors and incomplete turns are not counted as successful task completion.

## Regression tests changed/added

- Owner-scoped memory isolation between two users/profiles.
- TTL expiry suppression for memory retrieval.
- Prompt-envelope neutralization for stored text containing `</untrusted_data>`.
- Capability denial after a live policy changes, even with a previously valid capability.
- Provider failure reflected in `AgentLoop.lastTurnSucceeded`.

## Validation actually performed in this environment

| Check | Result |
|---|---|
| `bash -n` over all shell scripts | PASS — 7/7 |
| `python3 -m compileall -q scripts tools/mock_mcp_server` | PASS |
| YAML parsing | PASS — 23/23 |
| JSON parsing | PASS — 2/2 |
| Node JavaScript syntax check | PASS |
| Source invariants: `_loadSkill`, `rt.close`, `route.needTools`, owner-scope, `chatWithStatus` | PASS |
| SQLite owner filtering + TTL SQL expression smoke test | PASS |
| Dart SDK / Flutter SDK | NOT AVAILABLE |
| `dart pub get`, `dart analyze`, `dart test`, executable compile | NOT RUN |
| `flutter analyze`, `flutter test`, Web release build | NOT RUN |
| Real daemon, gateway delivery, Android/Termux and VPS integration | NOT RUN |

## Remaining release blockers / known gaps

This delta does not claim full PRD parity or production readiness. The latest source audit still identified work that is not completed in this patch:

- Cross-process session-store coordination/locking; unique temp files prevent filename collision but do not provide a transactional multi-process store.
- Scheduler outbound delivery acknowledgement/retry after the host gateway accepts or rejects the message. This patch fixes agent-generation status, not end-to-end delivery guarantees.
- Persistent skill approval records and a real isolated golden evaluator for skill promotion.
- Narrow resource-bound capability tokens (exact paths/domains/operation limits) rather than the current generic workspace capability.
- Wired subagent execution, adaptive DecisionProvider/tier routing, MCP Streamable HTTP configuration/lifecycle, and broader embedded/daemon feature parity.
- Full IANA timezone/DST support; scheduler currently supports only its documented fixed-offset zones.
- Circuit-breaker single-probe half-open behavior and deterministic handling when every provider is unhealthy.
- Complete Flutter admin UI and actual target-device integration testing.
- Standalone `10-PRD-PASITIKO-TIKO.md` was not present in the audited source archive, so this delta cannot certify every original PRD acceptance criterion.

## Required validation on a Dart/Flutter machine

From the repository root:

```bash
dart --version
flutter --version
dart pub get
bash scripts/validate.sh
```

The validation script performs strict analysis, package/app tests, deterministic calculator smoke, CLI setup/config/chat smoke, executable compilation, daemon/API smoke, and Flutter analysis/tests/Web build. Fix the first failing stage and rerun; do not bypass release gates with `|| true`.
