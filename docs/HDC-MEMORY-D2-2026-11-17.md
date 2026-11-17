# D2 — Memori Asosiatif HDC (Hyperdimensional Computing)

**Tanggal:** 2026-11-17
**Status:** Implementasi eksperimental, ter-wire di runtime, diuji.

## Ringkasan

D2 menambahkan memori asosiatif berbasis **Hyperdimensional Computing (HDC)** /
Vector-Symbolic Architecture sebagai pelengkap sistem memori yang sudah ada
(RAG + SQLite/Vec, layered memory, curated memory). Implementasi **pure Dart,
tanpa dependency baru**, sehingga aman untuk target edge (Flutter/Termux) dan
web (hanya `Uint8List` + `dart:math` — tidak ada literal integer 64-bit yang
bisa merusak `flutter build web`).

## Posisi yang jujur

- **BUKAN pengganti memori semantik.** Tidak ada model bahasa di balik
  encoder — similarity dihitung atas trigram karakter, bukan makna.
- **BUKAN klaim "kapasitas tak terbatas"** seperti wishlist umum HDC.
  Kapasitas efektif dibatasi `maxEntries` (default 1000) dengan eviksi FIFO.
- **In-memory** — hilang saat restart (by design, eksperimental).
- Cocok sebagai: asosiasi ringan, pencarian fuzzy karakteristik, komponen
  kognitif murah RAM di perangkat edge.

## Desain teknis

### Hypervector biner (`HdcVector`)

- Default **10.000 dimensi**, packed LSB-first ke `Uint8List` 1.250 byte
  (~12 KB per vektor).
- Operasi kognitif klasik VSA:
  - **binding** = XOR per byte — self-inverse (unbinding = binding ulang
    dengan vektor yang sama);
  - **bundling** = majority vote per bit — tie (tepat setengah) dipecahkan
    deterministik ke 0;
  - **permutation** = rotasi bit siklik — menyandikan urutan/posisi;
  - **similarity** = 1 − hamming/dimensions (popcount Kernighan).

### Encoder (`HdcEncoder`)

- Gaya Kanerva: teks dinormalisasi (lowercase, trim), di-pad `'  teks  '`,
  lalu setiap **trigram karakter** di-bind dengan posisinya
  (`char0 ⊗ perm1(char1) ⊗ perm2(char2) ⊗ perm(i)`), semua dibundle.
- Vektor karakter diturunkan **deterministik dari seed** (default 20261117)
  — encoder dengan seed sama selalu menghasilkan vektor sama.
- Batas **512 trigram pertama** untuk menjaga biaya CPU pada teks panjang.

### Toko (`HdcMemory`)

- `remember(id, text, {meta})` — id 1–128 char, text 1–10000 char; id sama
  menimpa; eviksi FIFO saat melebihi `maxEntries`.
- `recall(query, {topK, minSimilarity})` — top-k berdasarkan similarity,
  ambang opsional.
- `forget(id)`, `clear()`, `length`.
- Clock dapat diinjeksi (untuk test).

### Tool `hdc_memory` (`HdcMemoryTool`)

- Risk **low**, aksi: `remember` (id+text), `recall` (query, top_k 1–20,
  min_similarity 0–1), `forget` (id), `stats`.
- Gagal validasi → `ToolResult(isError: true)` dengan pesan Indonesia
  (pola fail-closed yang sama dengan `LayeredMemoryTool`).

## Wiring

- `packages/agent_memory/lib/src/hdc_memory.dart` — modul inti.
- `packages/agent_memory/lib/agent_memory.dart` — export barrel.
- `packages/tiko_runtime/lib/src/tiko_runtime.dart` — instansiasi
  `HdcMemory()` di sisi memori + `..register(HdcMemoryTool(hdcMemory))`
  setelah `SessionSearchTool`.

## Pengujian

`packages/agent_memory/test/hdc_memory_test.dart` — **25 test**:

- Determinisme seed (encode sama → hamming 0; seed beda → ~0.5).
- XOR self-inverse (`a.bind(b).bind(a) == b`).
- Majority bundling (bias → similarity > 0.9; kosong → ArgumentError).
- Permutasi (rotasi menurunkan similarity ~0.5; mempertahankan jarak;
  shift 0 identik).
- Similarity bounds (identik 1.0; acak 0.4–0.6; zero vector; dimensi
  tidak cocok melempar).
- Encoder: teks mirip > teks tak berkaitan; case-insensitive; teks
  kosong → zero; batas 512 trigram.
- Store: round-trip 1.0, urutan menurun, filter minSimilarity, clamp topK,
  query kosong, forget true/false, clear, overwrite, eviksi FIFO,
  validasi id/text, clock injeksi.
- Tool: metadata, alur remember→recall (format `similarity=`), error
  argumen hilang, forget ada/tidak ada, stats, aksi tidak dikenal → stats.

Hasil lokal: `dart analyze --fatal-warnings` bersih; `dart test`
**130 passing** (agent_memory), tiko_runtime **230 passing**.

## Batasan (by design, terdokumentasi)

- Tidak persisten (restart = hilang); persistensi opsional bisa jadi
  lanjutan bila terbukti berguna.
- Encoder trigram karakter — bukan semantik; teks dengan makna sama tapi
  kata berbeda tidak akan terdeteksi mirip.
- Satu proses, satu instance; tidak ada sinkronisasi lintas proses.
