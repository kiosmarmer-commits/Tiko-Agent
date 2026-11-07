# 01-ARSITEKTUR

- **ID dokumen:** AGD-01
- **Bergantung pada:** AGD-00

## 1. Prinsip desain (P)
| ID | Prinsip |
|---|---|
| P-01 | Provider-agnostic: inti agent tidak boleh mengimpor SDK vendor langsung |
| P-02 | Local-first: semua fitur harus bisa jalan dengan model lokal; cloud opsional |
| P-03 | Default-deny: tool berisiko butuh izin eksplisit |
| P-04 | Semua tool call dan keputusan model dicatat (audit) |
| P-05 | Bertahap: setiap fase menghasilkan sistem yang bisa dipakai |
| P-06 | Kapabilitas dideteksi (tool calling, vision, logprobs), tidak diasumsikan |

## 2. Topologi deployment
| Opsi | Deskripsi | Cocok untuk | Catatan |
|---|---|---|---|
| **A (disarankan)** | Daemon Dart (`dart compile exe`) di Termux/Linux/VPS + klien Flutter/CLI/Telegram | Pengguna HP tanpa PC | Android membatasi shell di app biasa |
| B | Semua di Flutter (Android) | Demo, tanpa tool shell | Tool terbatas; background kill oleh OS |
| C | Server di VPS, klien dari mana saja | Always-on | Perlu hardening keamanan |

## 3. Diagram layer
```
[Klien] CLI | Flutter UI | Telegram | Discord | Email | Web API
            │  (pesan dinormalisasi → InboundMessage)
            ▼
[Gateway]  auth allowlist · rate limit · session mapping
            ▼
[Agent Core] AgentLoop ── ContextBuilder ── Compactor
      │            │              │
      │            │              └─ MemoryRetriever (FTS5 + vektor + RRF)
      │            ├─ Router (DecisionProvider → pilih model/tool/izin)
      │            ├─ LlmProvider (OpenAI-compat | Ollama | Anthropic | Gemini)
      │            └─ ToolExecutor ── PermissionGate ── Sandbox
      ▼
[Tools]  built-in | script tools | MCP client | skills
[Storage] SQLite (drift): sessions, messages, memories, skills, jobs, audit
[Scheduler] tick loop → membuat InboundMessage internal
[Observability] log JSON, metrik token/biaya, audit
```

## 4. Struktur proyek (monorepo Dart)
```
agent_dart/
├─ pubspec.yaml                  # workspace
├─ packages/
│  ├─ agent_core/                # loop, interface, konteks (pure Dart, tanpa Flutter)
│  │  └─ lib/src/{agent_loop.dart, context_builder.dart, compactor.dart, router.dart}
│  ├─ agent_providers/           # adapter LLM + decision
│  │  └─ lib/src/{openai_compat.dart, ollama.dart, anthropic.dart, gemini.dart,
│  │              decision_jev.dart, decision_laya.dart, decision_llm_fallback.dart}
│  ├─ agent_tools/               # registry, built-in, script runner, MCP client
│  ├─ agent_memory/              # drift DB, FTS5, VectorIndex, retriever
│  ├─ agent_gateway/             # telegram, discord, email, http/ws server
│  ├─ agent_scheduler/
│  └─ agent_security/            # permission gate, sandbox, secret store, audit
├─ apps/
│  ├─ agentd/                    # daemon (bin/agentd.dart)
│  ├─ agent_cli/
│  └─ agent_flutter/             # UI klien (WebSocket ke agentd)
├─ skills/                       # folder skill (Markdown)
├─ tools/                        # script tools (tool.json + skrip)
├─ config/agent.yaml
└─ test/ (golden tasks, eval)
```

## 5. Interface inti (Dart)
```dart
abstract class LlmProvider {
  String get id;
  Capabilities get capabilities; // toolCalling, vision, logprobs, maxContext
  Stream<LlmEvent> chat(ChatRequest req); // text delta | toolCall | usage | done
  Future<List<double>> embed(String text); // opsional
}

abstract class DecisionProvider {
  Future<DecisionResult> decide(String state, Map<String, Question> questions);
}
sealed class Question {} // Choice(criteria), Score(range), Noul(yesNoUnknown)

abstract class Tool {
  ToolSpec get spec;           // name, description, jsonSchema, risk
  Future<ToolResult> run(Map<String, dynamic> args, ToolContext ctx);
}

abstract class MemoryStore {
  Future<void> addMessage(Message m);
  Future<List<MemoryHit>> search(String query, {int k = 8});
  Future<void> upsertFact(Fact f);
}

abstract class VectorIndex {
  Future<void> upsert(String id, List<double> v, Map<String, Object?> meta);
  Future<List<VectorHit>> topK(List<double> q, int k);
}
```

## 6. Agent loop (pseudokode)
```dart
Future<void> handle(InboundMessage m) async {
  final session = await sessions.get(m.sessionKey);
  final route = await router.route(m.text, session);          // DecisionProvider
  var ctx = await contextBuilder.build(session, m, route);    // memori + skill + tool spec
  for (var i = 0; i < cfg.maxIterations; i++) {
    final resp = await route.llm.chat(ctx.toRequest()).collect();
    if (resp.toolCalls.isEmpty) { await reply(m, resp.text); break; }
    for (final call in resp.toolCalls) {
      final verdict = await gate.check(call, session);        // izin / konfirmasi user
      final result = verdict.allowed ? await executor.run(call) : ToolResult.denied(verdict);
      await audit.log(call, verdict, result);
      ctx = ctx.withToolResult(call, result);
    }
    ctx = await compactor.maybeCompact(ctx);
    if (loopDetector.isLooping(ctx)) { await reply(m, 'Loop terdeteksi, berhenti.'); break; }
  }
  await memory.afterTurn(session);                            // simpan fakta, skill candidate
}
```

## 7. Alur data satu pesan
1. Gateway menerima pesan → autentikasi (ID pengguna di allowlist) → `InboundMessage`.
2. Router (Laya/Jev/LLM kecil) menjawab pertanyaan: kompleksitas, butuh tool, risiko.
3. ContextBuilder menyusun prompt: system + skill relevan + memori hasil retrieval + riwayat terkompaksi.
4. Loop LLM ↔ tool sampai jawaban akhir atau batas iterasi/token.
5. Jawaban dikirim balik; turn disimpan; kandidat memori/skill dievaluasi.

## 8. Contoh `config/agent.yaml`
```yaml
agent:
  max_iterations: 12
  max_tokens_per_task: 60000
providers:
  default_chat: ollama_local
  chat:
    ollama_local: {type: openai_compat, base_url: "http://127.0.0.1:11434/v1", model: "qwen3:8b"}
    cloud_main:   {type: anthropic, model: "<isi>", api_key_env: ANTHROPIC_API_KEY}
  decision:
    primary:  {type: laya, base_url: "http://127.0.0.1:8000"}   # laya-serve
    fallback: {type: llm_json, provider: ollama_local}
security:
  shell_allowlist: ["ls", "cat", "git status"]
  require_confirm: ["write_file", "shell", "http_post"]
telegram: {token_env: TG_TOKEN, allowed_user_ids: [123456789]}
```

## 9. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-01-01 | Buat workspace + paket kosong | `dart analyze` bersih |
| TASK-01-02 | Implementasi interface bagian 5 | Kompilasi + unit test mock |
| TASK-01-03 | Agent loop dengan provider tiruan | Test: 3 skenario tool call lulus |
