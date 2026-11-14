# /learn + Memori Terkurasi (MEMORY.md/USER.md) — 2026-11-15

Implementasi dua gap Hermes-parity tertinggi dari audit Qwen (bagian 2.2 dan
5.1/F4): perintah `/learn` untuk authoring skill otomatis, dan memori
terkurasi lintas sesi dengan nudge periodik. Referensi desain:
[dokumentasi skills Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills),
[dokumentasi memory Hermes](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory),
dan standar terbuka [agentskills.io](https://agentskills.io).

## 1. `/learn` — authoring skill dari sumber apa pun

Paritas Hermes: `/learn <sumber>` mengubah direktori, URL, catatan tempel,
atau percakapan berjalan menjadi `SKILL.md` draft yang tervalidasi — tanpa
menulis manual.

### Sintaks

```
/learn                          # distil dari percakapan sesi ini
/learn ./docs                   # dari direktori materi
/learn /tmp/runbook.md          # dari satu file
/learn https://docs.example.id  # dari URL (web_fetch)
/learn notes: langkah 1\nlangkah 2   # dari catatan tempel
/learn ./api --focus webhook    # fokus topik (opsional)
```

### Arsitektur

- `packages/agent_core/lib/src/learn.dart` — `LearnCommand.parse` (deteksi
  sumber: url/dir/file/notes/conversation), `LearnPrompt` (kontrak authoring
  standar house: deskripsi ≤60 char, seksi `## Langkah` + `## Kegagalan umum`,
  hanya tool nyata, output satu blok ```skill-markdown), `LearnOutput`
  (ekstraksi SKILL.md dari balasan model).
- `TikoRuntime._runLearnTurn` — satu-satunya funnel `chatWithStatus`, jadi
  `/learn` otomatis tersedia di **semua permukaan**: CLI, TUI, API daemon,
  Flutter, dan gateway. Turn authoring dijalankan dengan `toolFilter`
  read-only (`read_file`, `list_dir`, `grep`, `web_fetch`, `http_request`,
  `session_search`) — penulisan skill dilakukan runtime, bukan model.
- Validasi berlapis sebelum simpan: `SkillParser` → `SkillValidator`
  (ukuran ≤4KB + scan secret + tool dikenal) → `SkillScanner` (static scan)
  → slug belum dipakai → `SkillDraftBuilder.saveDraft` (atomic).
- Skill tersimpan sebagai **draft** di `skills/<slug>/SKILL.md`; promosi ke
  trial/approved tetap lewat alur lifecycle lama (`tiko skills evaluate
  <slug> --promote` lalu `tiko skills approve <slug>`).
- Event `skill.learned` dipancarkan ke event bus (terlihat di web UI/Flutter).

## 2. Memori terkurasi + nudge periodik

Paritas Hermes: dua file Markdown kecil yang di-inject ke system prompt
setiap turn, dijaga oleh nudge internal periodik, dengan anggaran karakter
ketat yang memaksa kurasi (bukan akumulasi).

### Komponen

- `packages/agent_memory/lib/src/curated_memory.dart`:
  - `CuratedMemoryStore` — `dataDir/memories/MEMORY.md` (fakta durabel) dan
    `USER.md` (profil pengguna); load/atomic-save; `snapshotPromptBlock()`
    untuk system prompt; anggaran karakter gabungan default **3575**
    (setara Hermes); operasi yang melebihi anggaran **ditolak**, bukan
    memotong konten lama.
  - `CuratedMemoryOps` — protokol teks satu-baris tanpa tool:
    ```
    ```memory-ops
    ADD MEMORY: deploy pakai port 5433
    ADD USER: pengguna suka jawaban ringkas
    REPLACE MEMORY: port 5432 => port 5433
    REMOVE USER: preferensi lama
    ```
    ```
    Blok diekstrak dari balasan model dan dibersihkan dari teks yang
    ditampilkan ke pengguna.
- `packages/tiko_runtime/lib/src/memory_nudge.dart` — `MemoryNudgeEngine`:
  counter per sesi (default tiap 10 turn, `memory.nudge_interval_turns`);
  directive sistem internal menyuruh model merefleksi dan mengeluarkan blok
  `memory-ops` bila ada fakta durabel; **setiap operasi dipindai PromptGuard
  (provenance agent) sebelum diterapkan — fail-closed** (nilai tambah di
  atas Hermes yang memindai berbasis pola terpisah); event `memory.curated`
  berisi applied/rejected.
- `RuntimeContext` — snapshot memori terkurasi di-inject ke system prompt
  (`Memori terkurasi lintas sesi:`), dan directive nudge di-inject sebagai
  system message pada turn yang jatuh tempo.

### Perintah chat terkait

- `/memory` — tampilkan isi MEMORY.md/USER.md + pemakaian anggaran
  (tersedia di semua permukaan lewat funnel yang sama).

### Konfigurasi (`config/agent.yaml`)

```yaml
memory:
  nudge_interval_turns: 10   # 0 = nonaktif
  curated_char_budget: 3575
```

## Keamanan

- Turn authoring /learn: toolset read-only, validasi + static scan, slug
  collision ditolak, skill selalu masuk sebagai `draft` (butuh approval).
- Memori terkurasi: PromptGuard memblokir operasi berpola injection/
  exfiltration (rule PI-005..PI-009, termasuk decode-and-rescan B-14);
  anggaran karakter fail-closed; penulisan file atomik (tmp+rename).

## Test baru

- `packages/agent_memory/test/curated_memory_test.dart` (7): parse/apply
  add-replace-remove, anggaran, replace tidak ditemukan, roundtrip atomik
  + snapshot, snapshot kosong, blok tanpa operasi valid.
- `packages/agent_core/test/learn_test.dart` (9): parse semua varian sumber,
  flag `--focus`, kontrak authoring, ekstraksi SKILL.md + integrasi
  SkillParser.
- `packages/tiko_runtime/test/memory_nudge_test.dart` (8): interval 10,
  counter per sesi, disabled, terapkan + bersihkan blok, blokir PromptGuard,
  balasan tanpa blok, isi directive.

## Verifikasi

- `dart analyze --fatal-warnings` — bersih.
- 25/25 test baru lulus; seluruh test package lulus (satu kegagalan
  pre-existing di `agent_calc` golden fixture yang tidak ter-track git,
  tidak terkait perubahan ini).
- `bash scripts/validate.sh` (Dart 3.13 + Flutter 3.47.5) — **VALIDATION PASS**.
