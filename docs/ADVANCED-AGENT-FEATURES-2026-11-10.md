# Fitur Agent Lanjutan — 10 November 2026

**Status:** Implemented (kode + unit test). Dart/Flutter SDK tidak tersedia di lingkungan penyusunan, sehingga bundle ini belum lolos `dart analyze --fatal-warnings` dan `dart test` lokal; validasi ditunggu pada CI.

Dokumen ini mendeskripsikan lima kelompok fitur agent lanjutan yang ditambahkan mengikuti pola Hermes Agent, Claude Code, dan agent coding modern lainnya.

## 1. Self-Improving Learning Loop — Reflection Stage

**Modul:** `packages/tiko_runtime/lib/src/reflection_loop.dart`
**Test:** `packages/tiko_runtime/test/reflection_loop_test.dart`

Melengkapi `SelfLearningEngine` (sintesis skill otomatis) dengan tahap refleksi ala Claude Code post-task review:

- `ReflectionEngine.reflect()` menganalisa trajectory sesi (`ConversationTurn`).
- Turn gagal menghasilkan *corrective lesson* (pemicu → insight → aksi).
- Trajectory sukses multi-tool menghasilkan *positive lesson* yang dapat dipromosikan menjadi skill oleh `SelfLearningEngine`.
- Pelajaran mirip tidak diduplikasi; counter `timesReinforced` naik (skoring relevansi ikut naik).
- `relevantLessons()` dan `buildContextPrompt()` menyuntikkan pelajaran paling relevan ke prompt berikutnya — loop tertutup lintas sesi.
- Persistensi JSON di `storePath`; file korup didegradasi menjadi store kosong, bukan crash.

## 2. Advanced RAG

**Modul:** `packages/agent_memory/lib/src/rag_pipeline.dart`
**Test:** `packages/agent_memory/test/rag_pipeline_test.dart`

Pipeline RAG lengkap di atas `VectorIndex` + `FtsIndex` yang sudah ada:

| Tahap | Kelas | Catatan |
|---|---|---|
| Chunking | `RagChunker` | Paragraph-aware, hard-wrap untuk paragraf oversized, overlap antar chunk |
| Query expansion | `QueryExpander` | Multi-query deterministik tanpa LLM round-trip |
| Hybrid retrieval | `HybridRetriever` | Dense (cosine) + BM25 lewat Reciprocal Rank Fusion (`k=60`) |
| Rerank | internal | Fusion score + lexical overlap dengan query |
| Context assembly | `RagPipeline.retrieve()` | Blok konteks dengan sitasi bernomor `[n] sumber: docId` |

Embedder disuntik host (`LlmProvider.embed`); tanpa embedder pipeline menurun ke lexical-only. `remove(docId)` menghapus semua chunk dokumen dari kedua index.

## 3. Multi-Agent Orchestration

**Modul:** `packages/agent_core/lib/src/agent_team.dart`
**Test:** `packages/agent_core/test/agent_team_test.dart`

Orkestrasi tim subagent ala Hermes v0.6:

- `AgentSpec` + `AgentRegistry`: anggota tim dengan role (`planner`, `researcher`, `coder`, `critic`, `summarizer`), system prompt, `toolAllowlist`, dan `modelTier`.
- `TaskGraph`: DAG tugas dengan deteksi siklus dan dependency tak dikenal (`StateError`).
- `TeamOrchestrator.run()`: eksekusi per-wave topologis; node independen dalam satu wave berjalan paralel dengan batas `maxConcurrency`; prompt node diberi awalan output dependency dari `Blackboard`.
- `Blackboard`: memori bersama dengan slot konvensional `result:<id>` / `dep:<id>` dan pencatat penulis.
- Eksekutor node dan synthesizer disuntik host; tanpa synthesizer, sintesis deterministik berupa gabungan output. Kegagalan executor ditangkap sebagai `TaskResult.success = false`, tidak melempar exception.

## 4. Enhanced Security

**Modul:** `packages/agent_security/lib/src/prompt_guard.dart`
**Test:** `packages/agent_security/test/prompt_guard_test.dart`

Melengkapi `TirithSecurityLayer` (bidang tool/approval) dengan guard bidang konten:

- `PromptGuard.inspectInput()`: deteksi prompt injection — instruction override (PI-001), ekstraksi system prompt (PI-002), delimiter chat-template (PI-003), persona jailbreak (PI-004), blob base64 (PI-005), instruksi tool-call tertanam (PI-006). Konten dari `Provenance` tak tepercaya (web/email/mcp/unknown) dinaikkan satu tingkat severity.
- `PromptGuard.inspectOutput()`: filter kebocoran — API key (OF-001), GitHub token (OF-002), private key (OF-003), bearer token (OF-004), email (OF-005), nomor telepon Indonesia (OF-006); temuan rendah menghasilkan teks tersanitasi `[REDACTED:*]`.
- `GuardVerdict`: `allow` / `sanitize` / `block` berdasarkan ambang severity yang dapat dikonfigurasi.
- `AnomalyDetector`: sliding-window rate per key untuk mendeteksi runaway loop dan credential stuffing.

## 5. Advanced Memory System

**Modul:** `packages/agent_memory/lib/src/memory_layers.dart`
**Test:** `packages/agent_memory/test/memory_layers_test.dart`

Memori berlapis model kognitif:

- `MemoryLayerType`: `episodic` (kejadian mentah), `semantic` (fakta/distilasi), `procedural` (how-to).
- `MemoryEntry.effectiveScore()`: importance × retention eksponensial gaya Ebbinghaus (`0.5^(age/halfLife)`) × access boost.
- `LayeredMemory.consolidate()`: entri episodic yang sering diakses dan penting dipromosikan menjadi entri semantic (distilasi), entri asli ditandai `consolidated` agar tidak dipromosikan dua kali; entri dengan skor efektif di bawah `decayFloor` dilupakan (`ConsolidationReport`: promoted/decayed/forgotten).
- `retrieve()`: lintas layer dengan bobot skor efektif, scoping `ownerKey`, dan tie-break deterministik.
- Persistensi JSON (`save`/`load`) toleran file korup.

## Integrasi

- Semua modul murni Dart tanpa dependency baru; mengikuti pola injection yang sudah dipakai repo (executor/embedder/synthesizer disuntik host).
- Export barrel: `agent_core.dart`, `agent_memory.dart`, `agent_security.dart`, `tiko_runtime.dart`.
- Wiring penuh ke `TikoRuntime` mengikuti pola `SelfLearningEngine` dan dapat dikerjakan bertahap tanpa perubahan kontrak publik yang ada.
