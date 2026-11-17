# D3 — Loop Koreksi-Diri untuk Script (Self-Correction)

**Tanggal:** 2026-11-17
**Status:** Implementasi eksperimental, opt-in, ter-wire di runtime, diuji.

## Ringkasan

D3 menambahkan loop koreksi-diri terbatas untuk eksekusi script: saat script
gagal (exit != 0 atau timeout), error dikirim ke advisor (LLM jalur auxiliar)
untuk menghasilkan **patch berupa script lengkap pengganti**, lalu dicoba
ulang — maksimal **3 percobaan eksekusi** (bounded 1..5). Setiap percobaan
tercatat di audit trail.

## Posisi yang jujur (vs wishlist Qwen "Self-Healing Wasm Sandbox")

- **BUKAN sandbox Wasm.** Tidak ada dependency Wasm yang matang untuk Dart
  (item roadmap Wasm dilaporkan **blocked**, bukan disembunyikan).
- **BUKAN analisis AST sungguhan.** Koreksi dilakukan LLM atas teks error
  (stderr/stdout), dengan validasi ketat atas hasil patch (fail-closed).
- Eksekusi tetap di **OS sandbox yang sama** dengan script tools
  (`SandboxRunner`); tanpa OS sandbox, loop ini **menolak jalan** — tidak
  ada fallback eksekusi host.
- Tanpa advisor (provider kosong / config off), tool tidak terdaftar atau
  hanya menjalankan sekali tanpa "perbaikan" (fail-closed).

## Desain teknis

### Loop (`SelfCorrectingScriptRunner`, agent_tools)

- API: `run({source, entryFile, command, args})` → `ScriptRunReport`.
- Validasi input fail-closed: source 1..20000 char tanpa `\0`;
  `entry_file` regex aman (tanpa `..`/dotfile); command 1..32 argumen
  dengan batas panjang; sandbox `none` tanpa executor override → StateError.
- Siklus per percobaan: tulis source ke file di temp dir privat → eksekusi
  via sandbox → sukses? selesai : minta patch → validasi patch
  (tidak kosong, dalam batas, **berbeda dari sebelumnya** — anti-loop) →
  tulis ulang → ulangi.
- Timeout diperlakukan sebagai kegagalan (`exit -1`, stderr `timeout`).
- `ScriptRunReport` = status + output + audit trail lengkap
  (`ScriptRepairAttempt`: run/patch/abandon, exit code, excerpt error,
  timestamp) + `auditSummary()` satu baris.
- Executor dapat diinjeksi (`executorOverride`) sebagai test seam —
  produksi selalu memakai `SandboxRunner`.

### Tool `script_selfheal`

- Risk **high** (mengeksekusi kode hasil LLM — konsisten dengan default
  script tools), timeout tool dibatasi 60 s.
- Aksi: kirim `source` (+ `entry_file`, `command`, `args` opsional) →
  output + `[audit]` trail; kegagalan → `isError` dengan stderr + audit.

### Advisor LLM (`LlmScriptRepairAdvisor`, tiko_runtime)

- Memakai `auxiliaryLlm()` (jalur auxiliar terbungkus breaker yang sama
  dengan skill synthesis/self-learning).
- Prompt ketat: balas **tepat satu blok kode** berisi script lengkap,
  tanpa penjelasan; `UNFIXABLE` untuk kasus tak bisa diperbaiki.
- Parsing fail-closed: ambil blok fenced **terakhir**; tanpa blok → pakai
  teks utuh; kosong/oversize/UNFIXABLE/LLM error → `ScriptRepairException`
  (loop berhenti dengan audit, bukan menebak).

### Config & wiring

- `script.self_repair` (YAML, default **false** — opt-in karena membakar
  token LLM dan mengeksekusi kode hasil LLM); nilai non-bool → ConfigIssue,
  jatuh ke false.
- Runtime: bila `cfg.scriptSelfRepair` dan `auxiliaryLlm() != null`,
  `ScriptSelfHealTool` terdaftar dengan `LlmScriptRepairAdvisor`; setiap
  report dikirim ke `AuditLog` (tool `script_selfheal`, risk high).

## Pengujian

- `packages/agent_tools/test/script_repair_test.dart` — **17 test**:
  sukses percobaan pertama; gagal→patch→sukses (source benar-benar
  ditulis ulang); berhenti di maxAttempts (pola run/patch/abandon tepat);
  timeout; tanpa advisor; advisor error; patch identik ditolak;
  patch kosong/oversize ditolak; sandbox none menolak; stdin JSON;
  validasi input; cleanup temp dir; metadata tool; alur tool end-to-end
  (sukses/gagal), argumen hilang, entry_file tidak aman.
- `packages/tiko_runtime/test/script_repair_advisor_test.dart` — **6 test**:
  ekstraksi fence terakhir, fallback tanpa fence, UNFIXABLE, kosong,
  LLM error, isi prompt.
- `tiko_config_test.dart` — +1 test `script.self_repair`.

Hasil lokal: `dart analyze --fatal-warnings` bersih; `dart test`:
agent_tools **321 passing**, tiko_runtime **237 passing**, agentd
**7 passing**.

## Batasan (by design, terdokumentasi)

- Patch = script lengkap pengganti (bukan diff) — sederhana dan aman,
  tapi boros token untuk script besar.
- Tidak ada persistensi antar-panggilan: setiap panggilan `script_selfheal`
  memulai loop baru; pembelajaran lintas-panggilan tetap lewat evolution
  engine (B4).
- Wasm sandbox: blocked (belum ada dependency Wasm matang untuk Dart).
