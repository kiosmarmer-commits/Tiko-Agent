# 06 — Algoritma Agent, Evaluasi dan Self-learning

> **Catatan status:** dokumen ini adalah panduan algoritma agent, evaluasi, dan self-learning. Source dan test pada commit `73bbec5` adalah kontrak implementasi; perubahan formula wajib mengikuti pedoman pengembangan.

**Snapshot:** `73bbec5` (20 November 2026).

Dokumen ini memisahkan algoritma yang ditemukan pada source dari mekanisme yang baru berupa rencana/konfigurasi opsional. Rumus di bawah merujuk default implementasi, bukan jaminan kualitas model.

## 1. Agent loop dan kontrol eksekusi

| Mekanisme | Implementasi | Kondisi |
|---|---|---|
| ReAct/tool loop | `AgentLoop.handle()` menjalankan LLM → izin → tools → hasil → context | Implemented |
| Budget guard | Maksimum iterasi, token, wall-clock seconds dan jumlah tool calls; konfigurasi dari `AgentConfig` | Implemented |
| Parallel tools | Izin diperiksa sekuensial; tool yang lolos dieksekusi paralel melalui `ParallelToolRunner` bila jumlah > 1 | Implemented |
| Loop detector | Menghentikan sesi bila tool + args identik berulang minimal tiga kali berturut-turut | Implemented |
| Context compaction | Context dikompaksi saat perlu menurut batas konteks | Implemented; kualitas ringkasan tetap perlu golden tests |
| Plan-and-execute | `PlanExecute` membuat daftar langkah; `plan_task` tersedia pada bootstrap daemon | Implemented sebagai helper/tool, bukan planner yang selalu mengendalikan loop |
| Reflection/critic | `Reflector` dapat memeriksa/merevisi jawaban; aktif melalui config/env/ambang tool | Optional |
| Self-consistency | Pengambilan beberapa sampel dan pemungutan jawaban; aktif lewat konfigurasi runtime | Optional, biaya tambahan |
| Subagent | `spawn_subagent` memanggil nested `chatWithStatus` dengan child session/depth marker | Implemented; tetap perlu uji budget/cancellation lintas nesting |
| Fallback provider | Setelah error, AgentLoop mencoba provider fallback maksimal sekali per provider per request | Implemented |

AgentLoop memeriksa seluruh izin tool sebelum menjalankan batch tool yang disetujui. Penolakan satu tool dapat membuat turn diklasifikasikan gagal meskipun tool lain dalam batch dapat berjalan.

## 2. Routing model

Router memilih tier 1–3 melalui DecisionProvider atau heuristic, memakai `providers.tiers`, health/latency score dan fallback. DecisionProvider dapat meminta keputusan tool/risk/complexity; bila model keputusan tidak tersedia, heuristic fallback digunakan. Rincian dan kondisi fallback ada di `02-PROVIDER-AI.md`.

Jangan menyebut routing sebagai “LLM selalu memilih model”: default config menggunakan mock dan DecisionProvider biasanya disabled sampai diaktifkan.

Provider mock punya pemilih behavior (`providers.chat.scenario`): plain | assisted | single_tool | multi_tool | loop_trap. Bila kosong, runtime kini memakai `assisted`: jawaban kontekstual deterministik — pertanyaan hitungan memanggil tool `calc` dan pertanyaan waktu memanggil `datetime` bila tool tersedia, sisanya balasan bantuan (cara setting provider dsb.) — sehingga percobaan tanpa LLM sungguhan tetap interaktif, bukan hanya satu kalimat greeting. Scenario `plain` tetap dipertahankan untuk unit test yang mengunci teks.

## 3. Retrieval algoritma

- SQLite path: FTS5/BM25 candidate dan vector candidate bila embedding tersedia, lalu Reciprocal Rank Fusion (RRF, `k=60`).
- Vector index yang dibuat oleh runtime saat snapshot: `BruteForceVectorIndex`.
- Tanpa embedding, jalur lexical/FTS tetap sumber utama; vector search tidak berjalan otomatis.
- ContextBuilder mengambil hingga lima memory hits untuk prompt dan membungkus memory sebagai `untrusted_data`.

## 4. Skill matching dan synthesis

### Matching

`SkillMatchScorer` menggabungkan kedekatan prompt dengan skill dan reliability historis:

`Score_gate = α × similarity + (1 − α) × reliability`

Default `α = 0.7`. Jika embedder tidak disediakan, similarity fallback menggunakan lexical Jaccard atas token. Reliability memakai success rate dan age decay; bobot reliability berkurang setengah setiap 30 hari tidak digunakan. Skor adalah heuristik/ranking, bukan ukuran kualitas model yang dikalibrasi.

### Synthesis dari turn

Turn yang sukses dan memakai beberapa tool dapat disintesis menjadi draft `SKILL.md`. `SkillSynthesis.evalScore` menggunakan:

`S_eval = w1 × success + w2 × toolComplexity + w3 × tokenEfficiency`

Default bobot `w1=0.5`, `w2=0.3`, `w3=0.2`, threshold default `0.85`. Bila synth LLM tidak tersedia/hasil tidak valid, ada fallback draft heuristik. Draft tidak otomatis menjadi skill approved.

### Promotion gate

Lifecycle mencakup scan statis, golden evaluation dalam AgentLoop yang terisolasi, status trial/approved secara eksplisit, serta rollback. Golden evaluator runtime memakai memory in-memory terpisah dan tool gate allowlist fail-closed. Approval wajib mengevaluasi pada proses yang sama sebelum mencatat status approved.

`SkillApprovalLedger` menyimpan status approval dan fingerprint konten. Edit konten mengubah fingerprint sehingga status approval lama tidak dipulihkan. `SkillMetricsLedger` menyimpan uses/successes/feedback counts/last-used secara terpisah; status approval tidak ditentukan oleh metrik.

**Belum selesai:** feedback 👍/👎 belum dipasang sebagai alur otomatis menyeluruh dari UI/chat ke registry sink. Sink metrics fire-and-forget bisa kehilangan event terakhir saat crash. Tidak ada fine-tuning otomatis; closed-loop learning berarti skills/memory/evaluation, bukan update bobot model.

## 5. Kalkulator `agent_calc`

`agent_calc` adalah mesin deterministic/exact, bukan LLM. Komponen:

- `Dec` berbasis BigInt untuk operasi desimal dengan scale dan mode rounding eksplisit.
- Tokenizer, recursive-descent parser, AST, evaluator dan batas ekspresi/kedalaman/hasil.
- Rewrite bahasa Indonesia (R1–R6), angka locale Indonesia/Inggris, suffix nilai besar, dan warning ambiguitas.
- Fungsi matematika dan konstanta; satuan/suhu; anuitas, amortisasi, saldo, IRR; statistik deskriptif; tanggal sipil Hinnant.
- `CalcSandbox.evaluate()` menjalankan evaluator pada isolate terpisah dengan timeout default dari `CalcLimits` (2 detik di implementasi M2); timeout membunuh isolate dan menghasilkan `CALC_E_TIMEOUT`.
- `CalcTool` pada runtime memakai jalur sandbox; CLI `tiko calc` menerima `--scale`, `--rounding`, `--locale`.

IRR adalah jalur numerik berbasis double/bisection (ditandai approximate); jangan menyebut seluruh fungsi kalkulator bebas floating-point. Semantik presisi dan rounding setiap fungsi statistik harus mengacu pada implementasi serta golden test spesifiknya.

## 6. Evaluasi

CI menjalankan unit test paket, golden fixtures kalkulator dan smoke CLI, tetapi tidak mengukur akurasi provider AI eksternal secara menyeluruh. Evaluasi router Indonesia, tool call selection, skill quality dan prompt-injection perlu test fixtures tersendiri. Angka success/accuracy tidak boleh dicantumkan tanpa dataset dan hasil run yang menyertainya.

## 6a. Reflection loop (baru)

`packages/tiko_runtime/lib/src/reflection_loop.dart` menambahkan tahap refleksi pada self-learning loop: `ReflectionEngine.reflect()` mendistilasi trajectory sesi menjadi lesson (corrective untuk turn gagal, positive untuk trajectory sukses multi-tool), reinforcement menggantikan duplikasi, dan `buildContextPrompt()` menyuntikkan lesson relevan ke prompt berikutnya. Modul ini melengkapi `SelfLearningEngine`; lihat `ADVANCED-AGENT-FEATURES-2026-11-10.md`.

## 7. Algoritma yang tidak boleh diklaim sebagai fitur aktif tanpa bukti

- Fine-tuning otomatis/online training model.
- Subagent paralel bebas tanpa depth/budget/permission control.
- Semantic retrieval berkualitas vector database besar pada default runtime.
- Reranker neural model yang tidak terlihat di jalur runtime.
- Self-consistency aktif secara default.
- Router yang memakai Jev/Laya pada default config tanpa konfigurasi eksternal.

## 8. /learn dan memori terkurasi (2026-11-15)

Dua gap Hermes-parity telah diimplementasikan (detail lengkap di
`LEARN-CURATED-MEMORY-2026-11-15.md`):

- **`/learn`** — authoring skill dari direktori/URL/catatan/percakapan.
  Turn authoring memakai toolset read-only; hasil tervalidasi
  (SkillValidator + SkillScanner) dan disimpan sebagai draft. Tersedia di
  semua permukaan lewat funnel `chatWithStatus`.
- **Memori terkurasi MEMORY.md/USER.md + nudge periodik** — setiap
  `memory.nudge_interval_turns` (default 10) agent menerima directive
  internal untuk mengeluarkan blok `memory-ops`; operasi dipindai
  PromptGuard (fail-closed) sebelum diterapkan dengan anggaran karakter
  ketat (default 3575). Snapshot di-inject ke system prompt setiap turn;
  `/memory` menampilkan status.

Bagian 2.2 laporan audit yang menyebut `/learn` ❌ dan "memory nudge ❌"
kini sudah tertangani.

## 9. Self-evolution engine (B4, 2026-11-16)

`packages/tiko_runtime/lib/src/self_evolution.dart` menutup lingkaran
evolusi diri: trajectory → reward → arbitrase → kurasi skill.

- **Trajectory ledger** (`TrajectoryLedger`) — JSONL ter-capped (default
  2000 record) di `<dataDir>/evolution/ledger.jsonl`. Setiap turn chat
  dicatat via `SelfEvolutionEngine.recordTurn()` (best-effort, buffered di
  memori; persist pada konsolidasi/stop agar hot path bebas I/O).
- **Reward hibrida** — `computeDeterministicReward()` selalu tersedia:
  0.6 × keberhasilan + 0.25 × kebersihan tool (1 − rasio error) + 0.15 ×
  feedback user (netral 0.5 bila tidak ada).
- **LLM-as-judge beranggaran** (`SelfRewardJudge`) — hanya trajectory
  ambigu (sukses dikontradiksi feedback 👎, atau sebaliknya) dinilai LLM
  dengan format ketat `SCORE:`/`REASON:`; maksimal
  `maxJudgePerDay` (default 20) panggilan per hari UTC. Reward akhir =
  blend 50/50 deterministik + judge.
- **Bandit UCB1** (`SkillBanditStats`) — statistik reward per skill;
  `selectSkill()` memakai UCB1 sehingga skill belum dicoba selalu
  dieksplorasi.
- **Quarantine konservatif** — skill dengan ≥ `collapseMinSamples`
  (default 5) sampel dan mean reward < `collapseThreshold` (default 0.2)
  didemosi ke `draft`, lesson korektif dicatat ke `ReflectionEngine` via
  `recordCorrectiveLesson()`, event `evolution.quarantined` dipancarkan,
  maksimal `maxQuarantinesPerDay` (default 3) per hari. Pemulihan lewat
  alur approval skill yang sudah ada.
- **Siklus** — `start()` menjalankan konsolidasi periodik (default 1 jam);
  `consolidate()` men-judge record ambigu, menghitung ulang bandit,
  meng-quarantine skill kolaps, flush ledger, simpan
  `evolution/state.json` (atomik) dan memancarkan
  `evolution.consolidated`.

Batas yang jujur: ini bukan fine-tuning model dan bukan RL neural —
sinyalnya terukur (hasil tool, feedback user, judge LLM beranggaran) dan
semua gagalan bersifat best-effort sehingga tidak pernah merusak turn.

## 10. Orkestra bot team (Fase C, 2026-11-21)

Paritas pola bot teams Hermes/Claude Code dalam satu panggilan:

1. **Plan** — planner anggota (tanpa tool) mendekomposisi tujuan menjadi JSON
   DAG. Parser `parseBotTeamPlan` fail-closed: id/prompt wajib, agent wajib
   anggota tim, dependensi wajib dikenal dan asiklik, maksimum 12 node —
   pelanggaran apa pun jatuh ke fallback satu node (tujuan dijalankan apa
   adanya), bukan rencana karangan.
2. **Execute** — `AgentSpec`/`TaskGraph`/`Blackboard` (agent_core) dieksekusi
   `TeamOrchestrator`: node independen berjalan paralel per-wave (konkurensi
   1..8), dependen menerima output upstream lewat prefix konteks. Persona,
   allowlist tool (null = tanpa tool), tier model, dan budget turn per
   anggota ditegakkan `chatWithStatus` (session `team:<team>:<node>`).
3. **Synthesize** — turn summarizer bila ada; tanpa summarizer → gabungan
   deterministik (tidak pernah mengklaim hasil yang tidak ada).
4. **Review** — anggota critic mengulas sintesis; advisory, bukan gate.
5. **Verify (opsional)** — `verify_command` dijalankan `runVerification`
   (kontrak Fase B: exit 0 satu-satunya bukti sukses; metachar dilarang;
   argv-exec tanpa shell bila tidak ada OS sandbox); gagal → maksimum 3 turn
   perbaikan anggota coder dengan tail output sebagai umpan balik.
6. **Persist + observability** — `success` akhir = semua node sukses DAN
   verify lulus; laporan JSON disimpan `data/teams/runs/`; event
   `team.plan_started/planned/node_started/node_finished/review_done/verify/finished`
   mengalir ke EventBus → `/v1/stream`.

Tim tersimpan `BotTeamStore` (`data/teams/<id>.json`) dipakai CLI
(`tiko team`) dan REST (`/v1/teams`); tim tanpa konfigurasi memakai roster
bawaan (planner, researcher, coder, critic, summarizer).
