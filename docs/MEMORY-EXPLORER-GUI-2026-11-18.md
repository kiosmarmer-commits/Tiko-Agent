# GUI-P1-12: Memory Explorer — 2026-11-18

Item **Memory Explorer / pembelajaran** (observabilitas GUI: "Lihat dan
kelola memori agent — kurasi MEMORY.md/USER.md, memori berlapis, dan
sumber RAG") — empat tampilan di atas endpoint nyata:

1. **Fakta**: daftar memori kurir read/delete (`GET/DELETE /v1/memory`)
   yang sudah ada.
2. **Kurasi**: isi `MEMORY.md`/`USER.md` + anggaran karakter dengan
   edit & simpan penuh per file.
3. **Lapisan**: CRUD entri memori episodic/semantic/procedural dengan
   pencarian retrieval lintas lapis.
4. **RAG**: dokumen sumber yang sudah di-chunk + terindeks (read-only).

## 1. Runtime (`packages/tiko_runtime`)

- `memoryCuratedGet()` — teks + jumlah karakter MEMORY.md/USER.md,
  `budget`/`used` dari `CuratedMemory`.
- `memoryCuratedSet({file, text})` — ganti penuh satu file; validasi
  file enum + proyeksi gabungan melebihi anggaran → `ArgumentError`
  (→ 400); persist via `curatedMemory.save()`.
- `memoryLayersGet({query, limit})` — dengan query memakai retrieval
  lintas lapis `layeredMemory.retrieve` (skor × relevansi); tanpa query
  semua entri urut terbaru; clamp limit 1..500; sertakan `stats()` per
  lapisan (count + avg_score), `total`, `truncated`.
- `memoryLayerAdd(...)` — validasi layer enum + teks non-kosong, add +
  persist; `memoryLayerDelete(id)` — remove + persist, id tidak ada →
  `StateError` (→ 404).
- `memoryRagSources({limit})` — kelompokkan chunk RAG per `doc_id`
  (jumlah chunk, 120 char pertama konten) + `truncated`; read-only.
- `RagPipeline.chunks` — getter read-only semua chunk terindeks.

## 2. Gateway (`packages/agent_gateway`)

- Route: `GET/PATCH /v1/memory/curated`, `GET/POST /v1/memory/layers`,
  `DELETE /v1/memory/layers/:id`, `GET /v1/memory/rag`. Method lain →
  404; auth bearer.
-`_validateMemoryCuratedPatch` (file enum + teks string cap sane),
  `_parseMemoryLayersQuery` (q/limit clamp 1..500), `_validateMemoryLayerPayload`.
- Callback null → `501 not_implemented` (bare daemon); DELETE tanpa id →
  400; id tak ditemukan → 404.

## 3. agentd wiring (`apps/agentd/bin/agentd.dart`)

- Enam provider memory explorer dipasang langsung ke runtime;
  `ArgumentError → 400 invalid_request`, `StateError → 404 not_found`.

## 4. Flutter (`apps/agent_flutter`)

- DTO: `CuratedFileInfo`, `CuratedMemoryInfo`, `LayerEntry`, `LayerStats`,
  `LayersSnapshot`, `RagDocInfo`, `RagSourcesInfo`.
- Klien: `memoryCurated`, `updateMemoryCurated(PATCH)`, `memoryLayers`
  (q/limit), `addLayerEntry(POST)`, `deleteLayerEntry(DELETE)`,
  `memoryRag`; repo typed untuk semua.
- `ui/memory_explorer_page.dart` (`MemoryExplorerPage`, 4 tab
  DefaultTabController):
  - **Fakta** — daftar + dialog hapus (perilaku lama dipertahankan).
  - **Kurasi** — progress anggaran karakter (merah bila penuh) + dua
    `TextField` MEMORY.md/USER.md + tombol Simpan per file; controller
    disinkron bila snapshot identitasnya berubah.
  - **Lapisan** — stats per lapisan, ikon per layer, `ExpansionTile`
    detail (teks, akses, owner, sesi), tombol Hapus ber-konfirmasi,
    FAB `btn-add-layer` membuka sheet (dropdown layer, teks, tag,
    slider importance); sukses/gagal ditampilkan via SnackBar.
  - **RAG** — header chunk/dokumen + daftar dokumen (chunk, karakter,
    pratinjau).
- Route `AppRoute.memory`: kini memven MemoryExplorerPage; data
  eksplorasi di-load saat pertama masuk route (bukan bagian dari 17 GET
  refreshAdmin) bersamaan dengan refresh admin, dengan tombol refresh
  yang menjalankan keduanya.

## 5. Web parity (`apps/agentd/web`)

- Tab **Memori** diperluas: card Kurasi (dua textarea + Simpan
  MEMORY.md/USER.md + informasi anggaran), card Memori berlapis (input
  query + reset, form tambah layer select/tags/importance/teks, daftar
  entri dengan tombol Hapus), card Sumber RAG (daftar dokumen).
- Buka tab memori memuat fakta + kurasi + lapisan + RAG; klik tombol
  Hapus pada entri mengirim `DELETE /v1/memory/layers/:id`; semua render
  `textContent` anti-XSS; test node +4 (29 total).

## 6. Dokumentasi & test

- Test: runtime 6 baru (kurasi budget/ganti, lapis list/query/add/delete,
  rag group), gateway 2 baru (validasi + 501), Flutter 5 baru (4 repo +
  5 view), web 4 baru.
- Verifikasi: `flutter analyze` bersih; `flutter test` 244 lulus;
  `flutter build web --release` sukses; `dart test` gateway + runtime
  lulus; `node --test` 29 lulus.

## Yang TIDAK termasuk

- **Tidak ada edit parsial** kurasi — form mengganti penuh isi file;
  penggabungan anggaran divalidasi backend.
- **Tidak ada hapus dokumen RAG** — read-only (halaman ingest tetap
  menjadi jalur penambahan).
- **Tidak ada edit entri berlapis** (hanya tambah/hapus) dan **tanpa
  alur forget/decay manual** — decay tetap terjadi via akses otomatis.
- Snapshot kurasi/lapisan/RAG tidak berubah otomatis saat runtime
  berjalan (refresh manual); tanpa streaming WS.
