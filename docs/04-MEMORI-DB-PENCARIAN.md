# 04 — Memori, Database dan Pencarian

> **Catatan status:** dokumen referensi ini berawal dari snapshot historis `69b6da421bf2a4682dce19e05d1ea608607250be`. Baseline GitHub `main` yang terakhir diverifikasi pada 10 November adalah `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711`; bundle implementasi lokal sesudah baseline itu dijelaskan di `STATUS-2026-11-10.md` dan belum lolos Dart/Flutter CI. Gunakan source sebagai kontrak implementasi dan dokumen ini sebagai panduan arsitektur, bukan bukti validasi bundle.

**Snapshot:** `69b6da421bf2a4682dce19e05d1ea608607250be`.

## 1. Backend aktual

`packages/agent_memory/pubspec.yaml` menggunakan `sqlite3` (`^2.4.6`) langsung; package tidak memakai ORM Drift. `DriftStyleMigrations` adalah nama wrapper migrasi bergaya versioned migration, bukan bukti dependency Drift. Migrasi raw SQLite menggunakan `PRAGMA user_version`; schema saat snapshot adalah versi **6**.

`TikoRuntime.create()` mencoba `SqliteMemoryStore.tryOpen(dbPath, vectorIndex, embedder)`. Jika berhasil, backend dibungkus `SafeMemoryStore` dan dilaporkan sebagai `sqlite-fts5`. Jika native SQLite tidak bisa dibuka, runtime menggunakan `PersistentMemoryStore` JSON dan menandainya degraded.

## 2. Entitas dan migrasi

Skema aktual bertambah melalui migrasi, bukan tabel rancangan lama yang ditulis sebagai satu CREATE TABLE. Tabel yang terlihat dari `drift_schema.dart` mencakup:

- `messages`: pesan sesi dengan role/content/tool/timestamp.
- `facts`: fakta terkurasi, termasuk provenance, confidence, TTL, state dan `owner_key`.
- `sessions`: metadata sesi/summary.
- `embeddings`: vektor dan metadata.
- `kv`: key/value runtime.
- `memories`, `skills`, `jobs`, `tool_audit`, `feedback`: tabel kompatibilitas/operasional yang dibuat oleh migrasi awal lanjutan.
- FTS virtual tables `facts_fts` dan `memories_fts` jika FTS5 tersedia.

Versi migrasi 5 menambahkan provenance/confidence/ttl/state pada `facts`; versi 6 menambahkan `owner_key` dan index owner/time. Fakta legacy tanpa `owner_key` tidak masuk ke owner-scoped retrieval sampai disimpan ulang oleh pemilik yang sesuai.

## 3. Retrieval

SQLite backend menggunakan FTS5/BM25 dan candidate vektor bila embedding/index aktif, lalu Reciprocal Rank Fusion (RRF) dengan `k = 60`; helper mengambil top-8 secara default. ContextBuilder memasukkan hingga top-5 memory hits yang relevan ke prompt. JSON fallback mempunyai pencarian lexical/BM25-like serta vector path yang bergantung konfigurasi.

Runtime selalu membuat `BruteForceVectorIndex`; embedding nonaktif secara default dan hanya dibuat bila `memory.embed.enabled` aktif. Jangan tulis bahwa `sqlite-vec` adalah backend default atau sudah terhubung ke runtime. Penggunaan sqlite-vec adalah opsi/riset terpisah sampai wiring dan test platform membuktikannya.

## 4. Kebijakan memory

Memory store memakai owner scope, provenance/confidence dan TTL/state. `SafeMemoryStore` menjadi batas safety bersama untuk backend SQLite dan JSON. Retrieved memory ditandai sebagai data evidence/untrusted; konten memory bukan instruksi sistem dan tidak boleh menaikkan izin tool. Penyimpanan eksplisit dari user dapat membuat fact dengan `ownerKey` dari sesi; retrieval antar pemilik tidak boleh tercampur.

Runtime tidak boleh menyimpan secret (API key/password/credential) sebagai fakta. Validasi/redaksi dan batasan store harus dipertahankan saat menambah jenis memori baru.

## 5. Session history terpisah dari memory facts

`FileSessionStore` menyimpan session history di `sessions.json`; file ini bukan tabel `sessions` SQLite. Store menggunakan antrean transaksi in-process dan exclusive file lock lintas proses, melakukan refresh dari disk di dalam lock sebelum update, lalu menulis atomik. Tujuannya mencegah lost update ketika CLI/daemon/dua runtime berbagi path yang sama.

Jobs, approval, skill approval, skill metrics dan offline queue juga memiliki penyimpanan file masing-masing; jangan menyatakan semua state tersebut tinggal di satu SQLite database.

## 6. Web search dan fetch

`WebSearchTool` memakai SearXNG self-host sebagai mesin utama. Tavily merupakan fallback opsional hanya bila API key tersedia dan SearXNG gagal pada transport/timeout atau HTTP 5xx. Fallback tidak dipakai untuk HTTP 403 (konfigurasi JSON), 4xx lain, ataupun hasil kosong. Hasil dipetakan ke format sitasi yang sama; cache URL/snippet TTL satu jam.

Pencarian dapat fetch isi top-N hasil; setiap URL melewati SSRF guard, teks dipotong pada batas output, dan konten web dikembalikan sebagai data tidak tepercaya. Konfigurasi Tavily memakai `search.tavily_api_key: env:TAVILY_API_KEY`; secret mentah di YAML ditolak.

## 7. Konfigurasi

```yaml
storage:
  data_dir: data
  db_path: data/agent.db
memory:
  embed:
    enabled: false
    base_url: http://127.0.0.1:11434
    model: nomic-embed-text
search:
  searxng_base_url: http://127.0.0.1:8080
  # tavily_api_key: env:TAVILY_API_KEY
```

`memory.embed` memerlukan Ollama embedding endpoint/model yang benar. Nilai di atas hanya contoh; uji model pada host target.

## 8. Batasan

- SQLite FTS5 bergantung build/library SQLite native di device; JSON fallback bukan jaminan performa atau kesetaraan query.
- Brute-force vector retrieval dapat menjadi bottleneck pada jumlah vektor besar; benchmark target nyata masih diperlukan.
- Belum ada klaim sqlite-vec native lintas Termux/Android/iOS.
- SearXNG perlu mengaktifkan format JSON di `settings.yml`; HTTP 403 bukan pemicu Tavily fallback.
