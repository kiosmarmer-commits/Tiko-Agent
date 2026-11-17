# D4 — Audit Isolate Swarm + Fan-Out Paralel RAG

**Tanggal:** 2026-11-17
**Status:** Audit selesai; satu gap nyata ditemukan dan ditutup.

## Hasil audit (wishlist Qwen "Isolate Swarm" vs kode aktual)

| Kemampuan | Status sebelum D4 | Bukti |
|---|---|---|
| Eksekusi tool batch paralel | **Sudah tertutup** | `ParallelToolRunner` di `agent_loop.dart` — tool calls yang di-allow dijalankan paralel dengan filter `parallelSafe` + guard cancellation turn |
| Beban CPU murni + hard-cancel | **Sudah tertutup** | `CalcSandbox` (agent_calc) — isolate terpisah, dibunuh keras saat timeout, tidak pernah angka tebakan |
| Pool konkurensi generik | **Ada (dead code)** | `IsolatePool` + `ParallelSubagentRunner` (agent_core) — bounded worker + timeout, tapi tidak dipanggil jalur produksi mana pun; dipertahankan sebagai API publik, statusnya didokumentasikan jujur di sini |
| **Fan-out I/O RAG** | **GAP NYATA** | `RagPipeline.retrieve` mengeksekusi variant query **sekuensial** (await per variant); `ingest` mengeksekusi embedding per chunk sekuensial — padahal variant/chunk saling independen dan embedding adalah I/O ke provider |

## Yang diimplementasikan (gap yang ditutup)

### Fan-out paralel terbatas di `RagPipeline` (agent_memory)

- Parameter baru `maxConcurrency` (default **4**, assert 1..16; 1 = sekuensial).
- **`retrieve`**: semua variant hasil `QueryExpander.expand` di-embed dan
  di-fuse **konkuren terbatas** via `_mapBounded` (worker-queue di atas
  Future — single isolate, kooperatif di titik await).
- **`ingest`**: embedding semua chunk konkuren terbatas; **urutan hasil
  dipertahankan** sehingga upsert dense tetap berurutan per chunk.
- **Determinisme terjaga**: `_mapBounded` mengembalikan hasil dengan urutan
  sama seperti input, sehingga akumulasi skor RRF dan ranking identik
  dengan jalur sekuensial (dibuktikan test ekuivalensi).
- **Semantik error tidak berubah**: kegagalan embed saat ingest tetap
  propagate (fail-closed) seperti sebelumnya; `_safeEmbed` retrieve tetap
  fallback kosong.

### Kenapa bukan isolate untuk ini?

Embedding adalah **I/O-bound** (network call ke provider) — konkurensi
Future sudah cukup dan lebih murah dari spawn isolate (serialisasi + startup).
Isolate tetap dipakai untuk beban CPU murni yang sudah ada (CalcSandbox).
Ini framing jujur: tidak mengklaim "swarm puluhan micro-agent" — hanya
fan-out terbatas yang terukur manfaatnya.

## Pengujian

`packages/agent_memory/test/rag_concurrency_test.dart` — **7 test**:

- Ingest: 12 chunk ter-embed konkuren (puncak >1 dan ≤4), urutan index
  chunk terjaga.
- Retrieve: deterministik (dua panggilan sama → ranking sama), puncak
  konkurensi ≤ batas.
- **Ekuivalensi**: hasil paralel (4) identik skor+ranking dengan
  sekuensial (1).
- **Latensi**: retrieve paralel terukur lebih cepat dari sekuensial
  (embedder fake 30 ms, 3 variant).
- Embedder null → lexical-only tetap jalan; `maxConcurrency 1` = puncak 1;
  assert di luar 1..16 ditolak.

Hasil lokal: `dart analyze --fatal-warnings` bersih; `dart test`:
agent_memory **138 passing**, tiko_runtime **237 passing**, agentd
**7 passing**.

## Batasan (by design, terdokumentasi)

- `IsolatePool`/`ParallelSubagentRunner` tetap tanpa pemanggil produksi —
  bukan dihapus (API publik), tapi TIDAK diklaim sebagai fitur aktif.
- Fan-out RAG mempercepat I/O embed, bukan komputasi vektor (tetap di
  isolate utama; untuk skala besar, benchmark perangkat nyata masih
  blocked — butuh device/data).
