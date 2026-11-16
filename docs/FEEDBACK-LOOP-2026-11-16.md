# Feedback-to-Skill Loop End-to-End (C1) — 16 November 2026

Menutup gap P1 `09-ROADMAP-TASKS.md`: feedback 👍/👎 kini mengalir dari
chat/API ke **skill metrics durabel** dan **ledger trajectory self-evolution
(B4)** dalam satu jalur.

## Sebelum vs sesudah

| Jalur | Sebelum | Sesudah |
|---|---|---|
| Per-skill: `POST /v1/skills/<slug>/feedback`, `/feedback <slug> up\|down` | Sudah ada (P1-03) | Tetap |
| Tingkat turn: `/feedback up\|down` (tanpa slug) | ❌ | ✅ command chat agentd |
| Tingkat turn: `POST /v1/sessions/<id>/feedback` | ❌ | ✅ endpoint API (auth Bearer sama) |
| Feedback → ledger evolusi (reward re-blend) | ❌ | ✅ `SelfEvolutionEngine.recordFeedback()` |

## Implementasi

- `tiko_runtime/self_evolution.dart`:
  - `TrajectoryRecord.feedback`/`deterministicReward` kini mutable;
    konstruktor menghitung reward deterministik otomatis bila tidak
    diberikan; `applyFeedback()` me-reblend reward sehingga sinyal manusia
    langsung terlihat oleh bandit UCB1 dan quarantine.
  - `TrajectoryLedger.attachFeedback(sessionId, positive)` — update record
    terakhir sesi + rewrite file (atomik via `.tmp` + rename).
  - `SelfEvolutionEngine.recordFeedback()` — attach + event
    `evolution.feedback`; `false` bila sesi belum punya trajectory.
- `tiko_runtime/tiko_runtime.dart`:
  - `_sessionSkillsUsed` (in-memory, cap 500 sesi) diisi `chatWithStatus`
    dari `loop.lastSkillsUsed`.
  - `applyTurnFeedback({sessionId, positive, actor})` — feedback ke semua
    skill aktif pada turn terakhir (registry + sink durabel +
    `flushPendingSinks`), ke ledger evolusi, ke `AuditLog` (tool
    `feedback`, risk `low`), dan event `feedback.turn`.
- `agent_gateway`:
  - `SkillApi.recordSessionFeedback()` (abstract) + route
    `POST /v1/sessions/<id>/feedback` di `http_api.dart` (auth token server
    yang sama; session id divalidasi non-kosong tanpa `/`).
- `agentd`:
  - `RuntimeSkillApi.recordSessionFeedback()` memanggil
    `rt.applyTurnFeedback(actor: 'api')`.
  - `/feedback up|down` (dua token) → feedback turn terakhir sesi gateway
    (`sessionId = sessionKey`); `/feedback <slug> up|down` tetap per-skill.

## Batasan

- Pemetaan sesi→skill in-memory: setelah restart daemon, feedback turn
  terakhir prarestart tetap mencatat ke ledger evolusi (berbasis
  sessionId) tetapi tidak lagi mengenai skill metrik. Feedback per-skill
  via endpoint slug tidak terpengaruh.
- Feedback tetap telemetri: tidak pernah mempromosikan skill draft/trial;
  satu-satunya efek status adalah jalur negative yang sudah ada di
  `SkillRegistry.applyFeedback` (retire/demote bila successRate < 0.5).

## Tes

- `packages/tiko_runtime/test/self_evolution_test.dart`: +3 kasus (reblend
  reward, persist attachFeedback lintas reload, engine.recordFeedback
  event + unknown session).
- `apps/agentd/test/skill_feedback_api_test.dart`: +2 kasus (endpoint sesi
  setelah `rt.chat` mock → ledger evolusi berisi feedback; sesi tanpa turn
  tetap tercatat dengan daftar skill kosong).
- Hasil lokal: `dart analyze` bersih (tiko_runtime, agent_gateway, agentd);
  `dart test` — tiko_runtime 223, agent_gateway 96, agentd 7, semua lulus.
