# Tiko-Agent

Autonomous AI agent dalam Dart, terinspirasi Hermes Agent (Nous Research). Monorepo workspace berisi paket-paket inti, runtime, gateway multi-channel, dan aplikasi CLI/API/Flutter.

## Struktur

| Paket | Isi |
|---|---|
| `packages/agent_core` | Agent loop, router, context builder, compactor, skills, plan-execute, **multi-agent orchestration** (`agent_team.dart`) |
| `packages/agent_providers` | Provider chat/decision (OpenAI, Anthropic, Gemini, Ollama compat), circuit breaker, capability probe |
| `packages/agent_tools` | Tool registry, sandbox, browser automation, MCP loader |
| `packages/agent_memory` | SQLite/JSON memory store, FTS5/BM25, vector index, **Advanced RAG** (`rag_pipeline.dart`), **layered memory** (`memory_layers.dart`) |
| `packages/agent_security` | Permission gate, Tirith security layer, approval, redaction, **content-plane guard** (`prompt_guard.dart`) |
| `packages/agent_gateway` | Gateway Telegram, Discord, Slack, WhatsApp, Email, webhook, voice loop |
| `packages/agent_scheduler` | Scheduler dan job store (cron) |
| `packages/tiko_runtime` | Composition root: config, event bus, approval broker, **self-learning engine + reflection loop** |
| `apps/*` | `agentd` (daemon), `agent_cli`, `tiko` (Flutter) |

## Fitur agent lanjutan

Lima kelompok fitur ala Hermes Agent / Claude Code sudah tersedia sebagai modul murni yang diuji unit test (lihat `docs/ADVANCED-AGENT-FEATURES-2026-11-10.md`):

1. **Self-Improving Learning Loop** — `SelfLearningEngine` (sintesis skill otomatis) + `ReflectionEngine` (refleksi trajectory → lesson → injeksi prompt).
2. **Advanced RAG** — chunking, query expansion, hybrid retrieval (dense + BM25, RRF), rerank, context bersitasi.
3. **Multi-Agent Orchestration** — `AgentRegistry`, `TaskGraph` DAG, `TeamOrchestrator` paralel per-wave, `Blackboard` bersama.
4. **Enhanced Security** — deteksi prompt injection, filter kebocoran secret/PII, anomaly rate detector.
5. **Advanced Memory System** — memori berlapis episodic/semantic/procedural dengan konsolidasi dan decay Ebbinghaus.

## Menjalankan

```bash
dart pub get
dart analyze --fatal-warnings
dart test
```

Panduan instalasi lengkap: `INSTALL.md`. Dokumentasi arsitektur: `docs/00-INDEX.md`.
