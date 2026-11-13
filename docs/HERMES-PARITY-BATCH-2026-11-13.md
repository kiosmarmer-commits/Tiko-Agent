# Batch Optimisasi Prioritas Hermes-Parity (2026-11-13)

Basis: analisis pembandingan Tiko-Agent vs Hermes Agent dan daftar prioritas optimisasi (feedback loop skill, unified provider health, cancellation kooperatif, sqlite-vec default + hybrid rerank, korpus eval prompt-injection). Kelima prioritas dikerjakan tuntas dalam batch ini; pipeline RL gaya Atropos tetap long-term dan tidak disentuh.

## Item yang dikerjakan

| ID | Item | Implementasi |
|----|------|--------------|
| OPT-1 | Feedback loop 👍/👎 end-to-end | Akar masalah: `SkillApi` tidak pernah diekspor dari `agent_gateway` sehingga tak punya implementasi. Kini diekspor, diimplementasi `RuntimeSkillApi` (agentd, fail-closed untuk draft/retired), endpoint REST `/v1/skills/<slug>/feedback` + UI web (tab Skills, tombol 👍/👎), dan `TikoRuntime` mengekspos `skills.applyFeedback`. Race bug nyata ditemukan dan diperbaiki: `_flush()` konkuren di `SkillMetricsLedger` menimpa file `.tmp` yang sama (kehilangan event + `PathNotFoundException`) — kini diserialisasi via rantai future. `SkillSinkLedger` mendapat `flushPendingSinks()` agar tulisan sink terlacak |
| OPT-2 | Unified provider health state machine | `CircuitBreaker` (agent_providers) ditulis ulang sebagai adapter tipis di atas `ProviderHealth` (agent_core) — satu implementasi state machine, bukan dua. `TikoRuntime` menambah `breakerFor(providerId)`, `recordProviderFailure()`, `recordProviderSuccess()` sehingga Router dan breaker berbagi state yang sama; `BreakerLlmProvider` mengukur latensi (Stopwatch) dan meneruskan pesan error |
| OPT-3 | Cancellation kooperatif per-tool | Modul `cancellation.dart`: `CancellationToken` single-use dengan `guard()` (race action vs pembatalan), `OperationCancelledException`, `CancellationRegistry` (`begin()` per turn). Terhubung: `ToolContext.cancelToken`, `AgentLoop.handle(cancelToken:)` + `cancelTurn()` (cek di batas iterasi & tool batch), `TeamOrchestrator.run(cancelToken:)` (node dependen dilewati), runtime `cancellations` registry + `cancelTurn(sessionId)` + chain token subagent (marker `/sub/`) + `cancelAllTurns()` di `close()` |
| OPT-4 | sqlite-vec default + hybrid semantic rerank | `SqliteVecIndex` mendapat `remove(id)` + `length`; `SqliteMemoryStore.vectorIndex` kini bisa disetel (warm-up dilewati untuk index durable); runtime memakai `SqliteVecIndex(sqlite.db)` sebagai index default saat SQLite tersedia (backend `sqlite-fts5+vec`). `RagPipeline`: cache vektor chunk saat ingest + hybrid rerank `0.4*fusedNorm + 0.4*semantic + 0.2*overlap` saat embedder tersedia; tanpa embedder formula leksikal lama dipertahankan (backward compat) |
| OPT-5 | Korpus eval prompt-injection berlabel | `injection_eval.dart` (agent_security): `InjectionEvalCase` (teks, provenance, ekspektasi allow/sanitize/block), `InjectionEvalHarness.run()` + `accuracy()`, korpus `indonesianInjectionEval40` — 40 kasus Indonesia berlabel (20 benign termasuk adversarial-benign seperti roleplay tanpa kata kunci jailbreak, 17 block, 3 sanitize) mencakup seluruh keluarga rule PI-001..PI-006 dengan eskalasi provenance untrusted. Deterministik, tanpa LLM call |

## Keputusan desain

- CircuitBreaker mendelegasikan ke `ProviderHealth`, bukan membungkus provider — menghindari penghitungan failure ganda karena `AgentLoop` sudah mencatat tepat satu kali via `router.recordFailure/recordSuccess`.
- Cancellation bersifat kooperatif: `guard()` me-race future; pekerjaan latar tetap drain; tool membaca token via `ToolContext.cancelToken`.
- `CancellationRegistry.begin()` mengganti token per turn (`tokenFor()` salah semantik — bisa mengembalikan token yang sudah cancelled).
- Hybrid rerank RAG backward-compatible: `embedder == null` mempertahankan formula `fused + 0.1*overlap` persis seperti semula.

## Tes

- `packages/agent_core/test/skill_feedback_sinks_test.dart`: 3 kasus (durabilitas ledger, feedback tak pernah mempromosikan draft, `flushPendingSinks`).
- `packages/agent_core/test/cancellation_test.dart`: 12 kasus (token, registry, ToolContext, TeamOrchestrator).
- `packages/tiko_runtime/test/unified_health_test.dart`: 4 kasus (breaker↔Router berbagi state dua arah, sukses me-reset, backward compat standalone).
- `packages/agent_memory/test/rag_hybrid_rerank_test.dart`: 4 kasus (paraphrase mengungguli leksikal murni, backward compat tanpa embedder, cache vektor, pembersihan saat remove).
- `packages/agent_security/test/injection_eval_test.dart`: 5 kasus (akurasi korpus 1.0, cakupan kategori, determinisme, harness menandai mislabel, akurasi run kosong = 0.0).
- `apps/agentd/test/skill_feedback_api_test.dart`: 4 kasus e2e via `HttpApiServer` loopback (feedback REST sampai registry+ledger durable, draft ditolak fail-closed, slug/body tidak valid ditolak, GET memuat metrik).
- Lint lama `otel.dart` (3 info `prefer_final_locals`) ikut dibereskan.
- Full suite: 13 workspace member hijau — `dart analyze --fatal-warnings` bersih semua; `dart test` lulus semua (agent_core 145, agent_security 60, agent_memory 86, tiko_runtime 125, agent_providers 44, agent_gateway 63, agentd 5; app tanpa folder `test/` dilewati sesuai CI).

## Batasan yang dicatat

- Cancellation tidak memaksa tool native berhenti paksa; tool yang long-running diharapkan memeriksa `ToolContext.cancelToken` secara berkala.
- Hybrid rerank menambah satu pass cosine di atas kandidat top k*3 — biaya O(k) per retrieve, hanya aktif saat embedder terpasang.
- Korpus injeksi bersifat heuristik-deterministik (mengunci perilaku rule saat ini); korpus LLM-judge adversarial terpisah tetap menjadi pekerjaan lanjutan.
- Pipeline RL gaya Atropos (ekspor trajectory → training) tidak termasuk batch ini dan tetap di roadmap long-term.
