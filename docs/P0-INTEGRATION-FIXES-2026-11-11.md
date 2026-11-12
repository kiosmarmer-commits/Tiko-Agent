# Perbaikan Integrasi P0 — Audit Eksternal (2026-11-11)

Basis: audit eksternal (laporan ChatGPT) terhadap commit `cc57486`. Keenam temuan P0 diverifikasi satu per satu terhadap source; semuanya valid, lalu diperbaiki dalam satu batch.

## Verifikasi temuan

| ID | Temuan | Status verifikasi | Perbaikan |
|----|--------|-------------------|-----------|
| P0-1 | `_learnOnTurn()` mengirim `tokensUsed: 0` dan `ToolCall` sintetis tanpa args | Valid | `AgentLoop` kini merekam `ToolCallTrace` (args ter-sanitasi, `isError`, `durationMs`) dan mengekspos `lastToolCalls` + `lastTokensUsed`; runtime meneruskan telemetry asli ke `SelfLearningEngine.processTurn()` |
| P0-2 | `_improveSkill()` menimpa skill tanpa gate; `improvementScore` placeholder 1.0; `_loadStats/_saveStats` stub | Valid | Kandidat rewrite wajib lulus `SkillScanner.scanContent`; status demote ke `trial` (approval di-earn ulang); versi lama dibackup ke `versions/v<n>.md`; skor dihitung dari success rate + rasio feedback positif; stats persisten ke `learning_stats.json` (atomic tmp+rename) |
| P0-3 | Lesson refleksi tidak pernah diinjeksi ke context | Valid | `RuntimeContext` menerima `reflectionEngine` dan memanggil `buildContextPrompt(query)` per turn |
| P0-4 | RAG + LayeredMemory tidak ter-wire ke context builder | Valid | `RuntimeContext` menerima `ragPipeline` + `layeredMemory`; top-4 hit RAG (dengan sitasi) dan top-4 memori berlapis diinjeksi ke system prompt; semua best-effort (kegagalan retrieval tidak menggagalkan turn) |
| P0-5 | Tirith diinisialisasi tapi tidak pernah dipanggil di jalur chat utama | Valid | `_TirithPreGate` membungkus gate utama di `chatWithStatus()`: deny Tirith = final, sedangkan allowance/approval tetap satu jalur broker (tanpa double prompt). Capability Tirith memakai peek non-konsumsi (`CapabilityVault.peek`) agar token single-use tidak terbakar sebelum gate penegakan |
| P0-6 | Team runner tidak meneruskan `toolAllowlist`/budget per-role | Valid | Runner `agent_team` kini meneruskan `toolFilter` dari `AgentSpec.toolAllowlist` dan `configOverride` dengan `maxIterations = maxTurns` per role (budget eco-aware) |

## Batasan yang dicatat

- `modelTier` per-role kini **tuntas** diteruskan: `AgentConfig.preferredTier` → `Router.route(preferredTier:)` (override tier per panggilan, keputusan needTools/risk tetap dari teks); team runner memetakan `agent.modelTier` via `modelTierToRouterTier()`. Lihat `DEFERRED-COMPLETION-2026-11-12.md`.
- Tirith berperan sebagai lapisan deny/audit tambahan, bukan pengganti gate Matrix/Capability/Safety. Penegakan approval tetap satu jalur (`ApprovalBroker`).

## Tes

- `packages/agent_core/test/agent_loop_test.dart`: telemetry tool asli + args melewati sanitizer.
- `packages/tiko_runtime/test/runtime_context_test.dart`: lesson refleksi, RAG, dan layered memory tampil di system prompt; tanpa engine context tetap bersih.
- `packages/tiko_runtime/test/self_learning_improve_test.dart`: improvement lulus gate (trial + backup + skor terukur), ditolak static scan (file tak berubah), stats persisten antar instance.
