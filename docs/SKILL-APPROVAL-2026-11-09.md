# Laporan: Skill Approval Durabel + Evaluator Golden Terisolasi

Tanggal: 2026-11-09
Task: "Persistent skill approval records and a real isolated golden evaluator for skill promotion" (daftar blocker TIKO-REPAIR-STATUS-2026-11-07.md)
Branch: main

## Ringkasan

Sebelum perbaikan ini ada dua cacat pada alur promosi skill:

1. **Evaluate selalu gagal.** CLI membangun SkillPromotionGate tanpa evaluator,
   sehingga setiap "tiko skills evaluate" berhenti di tahap
   golden_runtime_unavailable (fail-closed by design). Tidak ada jalur
   promosi yang benar-benar mengeksekusi tugas golden.
2. **Approval tidak durabel.** SkillRegistry.loadFromDirectory memang
   sengaja mereset semua skill ke draft (status frontmatter YAML bukan
   record approval dan bisa diedit user), tetapi tidak ada penyimpanan
   approval durabel — hasil "tiko skills approve" hilang pada restart.

Perbaikan ini menambahkan (a) ledger approval durabel di agent_core,
(b) evaluator golden yang benar-benar terisolasi di TikoRuntime, dan
(c) wiring CLI yang memakai keduanya.

## Desain dan implementasi

### 1. Ledger approval durabel (baru: packages/agent_core/lib/src/skill_ledger.dart)

- SkillLedgerRecord: slug, action (evaluated / trial / approved /
  rolled_back / retired / eval_failed), actor, fingerprint, at, reason
  opsional, golden_score, golden_total.
- SkillApprovalLedger: file JSON (default data_dir/skill_approvals.json),
  maksimum 500 record terbaru, tulis atomik (file .tmp lalu rename),
  load fail-closed (file korup dibaca sebagai ledger kosong; semua skill
  tetap draft sampai ada evaluasi + approval baru).
- Fingerprint = FNV-1a 64-bit atas jsonEncode dari [slug, name,
  description, body, triggers, tools, version]. Tanpa dependensi baru
  (AGD-08); tujuannya mendeteksi edit konten, bukan menahan collision
  adversarial.
- applyTo(registry) dipanggil TikoRuntime.create tepat setelah
  loadFromDirectory: record terakhir per slug dipakai hanya bila
  fingerprint masih cocok dengan konten skill saat ini.
  - approved -> status approved + approvedBy dicatat ulang.
  - trial -> trial; retired -> retired.
  - rolled_back -> status dari field reason; approvedBy dihapus.
  - fingerprint tidak cocok -> tetap draft (wajib evaluasi + approve ulang).
  - golden_score/golden_total dipulihkan bila golden_total > 0.

### 2. Evaluator golden terisolasi (TikoRuntime.buildGoldenEvaluator)

Setiap tugas golden kini berjalan di AgentLoop sendiri via GoldenHarness
dengan isolasi penuh:

- memory evaluasi memakai SafeMemoryStore(InMemoryStore()) terpisah —
  evaluasi tidak pernah menyentuh memory/sesi produksi;
- SkillRegistry evaluasi hanya berisi salinan kandidat yang sedang diuji —
  skill lain tidak bisa dipakai, dan metrik skill produksi tidak terpolusi;
- _EvalToolGate (PermissionGate fail-closed) menolak semua tool di luar
  allowlist gabungan must_call + allowed_tools tugas + tools skill;
- SkillEvalConfig threshold 1.0 dan tanpa sessionStore/synthLlm —
  evaluasi tidak bisa menulis draft baru atau menyentuh sesi;
- hasil tetap dinilai SkillPromotionGate seperti biasa (min golden
  ratio 0.8; approve tetap wajib lulus evaluasi pada proses yang sama).

TikoRuntime mendapat metode publik evaluateSkill, approveSkill,
rollbackSkill yang membungkus gerbang, mencatat setiap hasil ke ledger,
dan menerbitkan event skill.evaluated / skill.approved / skill.rolled_back.

### 3. CLI (apps/tiko/bin/tiko.dart)

Kasus "skills" tidak lagi membangun gate sendiri; semuanya lewat runtime:

~~~
tiko skills evaluate <slug> [--promote]
tiko skills approve <slug> [--actor nama]     (default actor: cli)
tiko skills rollback <slug> [--to draft]
~~~

Fungsi helper _loadSkill dihapus (tidak lagi dipakai; validasi path kini
sepenuhnya milik SkillRegistry.loadFromDirectory yang sudah menolak
symlink escape dan file malformed/oversized).

## Test

- packages/agent_core/test/skill_ledger_test.dart (baru):
  round-trip + pemangkasan ke 500 record terbaru; file korup fail-closed;
  applyTo (frontmatter approved di-reset ke draft; fingerprint mismatch
  tetap draft; fingerprint cocok memulihkan approved + approvedBy + skor
  golden; rollback terakhir menang); fingerprint berubah saat body berubah.
- packages/tiko_runtime/test/skill_approval_test.dart (baru):
  evaluate -> draft; approve -> approved; restart -> masih approved
  (durabel, termasuk approvedBy dan golden_total); rollback -> draft;
  restart -> draft; slug tidak dikenal -> ArgumentError. Fixture memakai
  provider mock sehingga smoke task fallback gate lulus deterministik.
- File yang disentuh: skill_ledger.dart (baru), agent_core.dart,
  tiko_runtime.dart, tiko.dart, + 2 file test baru.

## Keterbatasan / follow-up

- Metrik uses/successes skill masih in-memory (tidak dipulihkan lintas
  restart); pencatatan metrik durabel adalah kandidat tugas berikutnya.
- Ledger bersifat at-least-once per aksi (append + flush per record);
  crash di antara dua aksi paling banyak kehilangan record terakhir dan
  tidak pernah meng-corrupt file (tulis atomik).
- Fingerprint FNV-1a bukan hash kriptografi; cukup untuk mendeteksi edit
  konten, bukan untuk model ancaman adversarial (lihat komentar kode).
