# E2: Konsolidasi Memori Idle via LLM — 2026-11-17

## Ringkasan

E2 menutup gap dari laporan Qwen ("Ebbinghaus Memory Compaction yang Proaktif"):
konsolidasi `LayeredMemory` yang sudah ada (B-series) bersifat deterministik dan
hanya menyalin teks entri verbatim. Kini entri episodik yang retensinya rendah
(hampir terlupakan) bisa diringkas menjadi fakta semantik padat via **LLM
auxiliar** saat runtime "idle", opt-in dengan cap harian.

## Komponen

### 1. `IdleMemoryConsolidator` (`packages/tiko_runtime/lib/src/idle_consolidation.dart`)

- **Pemicu idle**: hitung giliran sejak konsolidasi terakhir (default 25 giliran)
  — dipanggil setelah tiap giliran chat. Bukan timer latar belakang / isolate
  (dilaporkan jujur).
- **Kandidat**: entri episodik, belum `consolidated`, retensi ≤ `maxRetention`
  (default 0.5 — fokus yang hampir terlupakan), terlama dulu, dibatasi
  `maxEntriesPerBatch` (default 20) agar prompt terkendali.
- **Gerbang murah**: kandidat < `minCandidates` (default 5) → pass dibatalkan
  tanpa panggilan LLM.
- **LLM auxiliar**: prompt ketat (maks N fakta, satu per baris "- ", tanpa
  mengarang), `stream: false`, `temperature: 0.0`, `maxTokens: 1024`.
- **Parsing fail-closed**: hanya baris "- " valid (tidak kosong, ≤300 char),
  dibatasi `maxOutputFacts` (default 8); jawaban `NONE` → tanpa perubahan.
- **Efek**: fakta baru masuk layer semantik (importance = tertinggi kandidat,
  tag `konsolidasi-idle`); entri asli TIDAK dihapus — hanya ditandai
  `consolidated` dan dibiarkan dilupakan oleh decay/floor yang sudah ada.
- **Cap harian**: maks `maxSummariesPerDay` (default 6) panggilan LLM per UTC
  day — setiap panggilan dihitung, sukses atau gagal.
- Error LLM → event `memory.idle_consolidation_error`, tanpa perubahan memori.

### 2. Wiring `tiko_runtime`

- Config opt-in `memory.idle_consolidation` (default **false**): bentuk ringkas
  `true` atau mapping penuh (`idle_turns`, `min_candidates`,
  `max_entries_per_batch`, `max_summaries_per_day`, `max_retention`,
  `max_output_facts`). Nilai tidak valid → `ConfigIssue` + fallback default.
- Konsolidator dibuat hanya bila enabled **dan** ada provider LLM.
- Setelah pass sukses (fakta > 0): persist `layered_memory.json` segera +
  entri AuditLog (tool `idle_consolidation`, risk low) + event
  `memory.idle_consolidated`.
- Best-effort total: tidak pernah menggagalkan giliran chat.

## Batasan (dilaporkan jujur)

- "Idle" = jeda giliran chat yang cukup, bukan deteksi idle sistem/timer.
- LLM bisa meringkas keliru; mitigasi: prompt anti-karang + parsing ketat, tapi
  tidak ada verifikasi fakta otomatis.
- Entri asli tidak dihapus (hanya ditandai) — penghematan ukuran datang dari
  mekanisme forget yang sudah ada, bukan dari pass ini langsung.
- Konsolidasi deterministik lama (promosi akses-tinggi) tetap berjalan; pass
  ini adalah jalur tambahan untuk entri retensi-rendah.

## Pengujian

- `packages/tiko_runtime/test/idle_consolidation_test.dart` — 10 test:
  konsolidasi sukses, kandidat minimum, filter retensi, NONE, LLM error, cap
  harian, gate idle turn, parsing fail-closed, batas batch, metadata fakta.
- `packages/tiko_runtime/test/idle_consolidation_wiring_test.dart` — 2 test:
  nonaktif → null; aktif → terpasang + pass best-effort.
- `packages/tiko_runtime/test/tiko_config_test.dart` — +1 test parsing config.

Total: **13 test baru**. `dart analyze --fatal-warnings` bersih di tiko_runtime,
agent_memory, apps/agentd; `dart test` hijau (tiko_runtime 254, agent_memory
137, agentd 7).
