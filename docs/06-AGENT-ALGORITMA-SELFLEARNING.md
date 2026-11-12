# 06 — Algoritma Agent, Evaluasi dan Self-learning

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be`.

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
