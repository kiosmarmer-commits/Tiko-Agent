# Catatan Riset sqlite-vec — Belum Menjadi Backend Runtime

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Status pada 9 November 2026:** `sqlite-vec` belum menjadi vector index default dan belum di-wire sebagai backend utama `TikoRuntime`.

Runtime pada commit `69b6da421bf2a4682dce19e05d1ea608607250be` secara eksplisit membuat `BruteForceVectorIndex`. Embedding hanya diaktifkan melalui `memory.embed`; tanpa embedding, FTS5/BM25 tetap jalur retrieval utama. Bila SQLite native tidak tersedia, memory beralih ke JSON-backed persistent store.

## Mengapa catatan ini dipertahankan

`sqlite-vec` pernah dipertimbangkan untuk mengatasi skala brute-force dan integrasi vector search dalam database. Catatan ini adalah riset/decision context, bukan petunjuk bahwa extension sudah aktif.

## Persyaratan sebelum integrasi

1. Implementasikan adapter index dan wiring eksplisit pada `TikoRuntime`/`SqliteMemoryStore`.
2. Uji loading extension terhadap SQLite binary pada Linux, Termux/Android dan target lain yang benar-benar didukung.
3. Tentukan strategi static link/dynamic load dan license/artifact distribution.
4. Sediakan fallback otomatis ke `BruteForceVectorIndex` saat extension gagal dimuat; perilaku ini belum boleh dianggap ada sebelum test membuktikannya.
5. Uji migration, delete/update, owner-scope, TTL, corruption dan ranking parity.
6. Benchmark p50/p95 latency dan memory footprint terhadap brute-force pada ukuran dataset representatif.

## Contoh pemeriksaan eksploratif

```bash
# Linux: build/load extension sesuai panduan upstream sqlite-vec.
# Termux/Android: validasi ABI dan izin load extension pada device nyata.
# Jangan menyalakan extension yang tidak diverifikasi dari sumber tepercaya.
```

Untuk kondisi runtime saat ini, baca [`04-MEMORI-DB-PENCARIAN.md`](04-MEMORI-DB-PENCARIAN.md) dan backlog [`09-ROADMAP-TASKS.md`](09-ROADMAP-TASKS.md).
