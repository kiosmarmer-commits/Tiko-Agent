# 04-MEMORI-DB-PENCARIAN

- **ID dokumen:** AGD-04
- **Bergantung pada:** AGD-01, AGD-02

## 1. Pilihan database
| Kebutuhan | Pilihan | Status | Catatan |
|---|---|---|---|
| ORM/query | `drift` **2.32.0** (MIT, ±3.000★, rilis ±23 hari sebelum sinkronisasi) | ✅ aktif | Reaktif, migrasi, dukung FFI |
| Driver SQLite | `sqlite3` (Dart, FFI) | ⚠️ cek versi | Dipakai drift pada Dart/Flutter |
| Hindari | `floor` (rilis terakhir 1.5.0, ±2 tahun lalu) | ❌ | Tidak aktif |
| Teks penuh | SQLite **FTS5** | ✅ bawaan SQLite | Perlu build SQLite dengan FTS5 (periksa di Termux/Android) |
| Vektor | `sqlite-vec` v0.1.9 (Mar 2026), MIT/Apache | ⚠️ **pra-v1**, bisa ada breaking change | Pantau penerus resmi SQLite `vec1` |
| Alternatif vektor | ObjectBox, Qdrant/Chroma (server) | ⚠️ | Hanya bila skala > ratusan ribu vektor |

**DEC-05:** definisikan `VectorIndex` (AGD-01). Implementasi awal = **brute-force cosine di Dart** untuk
≤ 50.000 vektor (cukup untuk memori pribadi); implementasi kedua = `sqlite-vec` setelah lulus tes
pemuatan ekstensi di target (Linux, Termux, Android). iOS melarang pemuatan kode dinamis, jadi ekstensi
harus dikompilasi statis di sana.

## 2. Skema SQLite (ringkas)
```sql
CREATE TABLE sessions(id TEXT PRIMARY KEY, channel TEXT, user_key TEXT, title TEXT,
  created_at INTEGER, updated_at INTEGER, summary TEXT);
CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
  tool_name TEXT, tokens INTEGER, created_at INTEGER);
CREATE VIRTUAL TABLE messages_fts USING fts5(content, content='messages', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2');
CREATE TABLE memories(id TEXT PRIMARY KEY, kind TEXT,      -- fact | preference | episode
  text TEXT, source_session TEXT, importance REAL, created_at INTEGER, last_used_at INTEGER,
  expires_at INTEGER, embedding BLOB, status TEXT);        -- active | archived
CREATE VIRTUAL TABLE memories_fts USING fts5(text, content='memories', content_rowid='rowid');
CREATE TABLE skills(slug TEXT PRIMARY KEY, version INTEGER, status TEXT, uses INTEGER,
  successes INTEGER, last_used_at INTEGER, path TEXT, sha256 TEXT);
CREATE TABLE jobs(id TEXT PRIMARY KEY, cron TEXT, prompt TEXT, channel TEXT, user_key TEXT,
  next_run INTEGER, last_run INTEGER, enabled INTEGER, missed_policy TEXT);
CREATE TABLE tool_audit(id INTEGER PRIMARY KEY, ts INTEGER, session_id TEXT, tool TEXT,
  args_json TEXT, verdict TEXT, result_summary TEXT, duration_ms INTEGER, error TEXT);
CREATE TABLE feedback(id INTEGER PRIMARY KEY, session_id TEXT, message_id INTEGER, rating INTEGER, note TEXT);
CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT);
```
Aktifkan `PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;`. Tokenizer `unicode61` cukup untuk bahasa Indonesia
(tanpa stemming); stemming ringan bisa ditambahkan di sisi Dart bila perlu.

## 3. Jenis memori
| Jenis | Isi | Penyimpanan | Kapan dipakai |
|---|---|---|---|
| Working | Ringkasan sesi + N pesan terakhir | konteks prompt | Setiap turn |
| Episodik | Riwayat percakapan | `messages` + FTS5 | Pencarian lintas sesi |
| Semantik | Fakta/preferensi user | `memories` + embedding | Retrieval top-k |
| Prosedural | Skill | `skills/` + tabel `skills` | Trigger/relevansi |

## 4. Retrieval hibrida (RRF)
```dart
// Reciprocal Rank Fusion: skor = Σ 1 / (k + rank_i), k = 60
List<Hit> rrf(List<List<Hit>> rankings, {int k = 60, int top = 8}) {
  final score = <String, double>{};
  for (final r in rankings) {
    for (var i = 0; i < r.length; i++) {
      score.update(r[i].id, (s) => s + 1 / (k + i + 1), ifAbsent: () => 1 / (k + i + 1));
    }
  }
  final ids = score.keys.toList()..sort((a, b) => score[b]!.compareTo(score[a]!));
  return ids.take(top).map(byId).toList();
}
```
Alur: query → (a) FTS5 BM25 top 20, (b) vektor top 20 → RRF → (opsional) reranker → top 8 → batas token.

## 5. Kebijakan tulis memori
1. Model mengusulkan fakta; kode memvalidasi: panjang ≤ 300 karakter, tidak berisi rahasia (regex kunci API/kartu).
2. Deduplikasi: cosine > 0.92 terhadap memori aktif → gabung/perbarui, bukan tambah.
3. `importance` 0–1 dari DecisionProvider (Score) + sinyal eksplisit user ("ingat ini").
4. Peluruhan: memori tidak dipakai > 180 hari dan importance < 0.3 → `archived`.
5. User bisa melihat, mengedit, dan menghapus memori (perintah `/memory`).
6. **Jangan simpan** data sensitif (nomor identitas, kartu, kata sandi) dan jangan simpan instruksi yang
   melemahkan keamanan (mis. "jangan minta konfirmasi lagi").
7. Memori dari konten web/MCP diberi `source` dan tidak boleh langsung menjadi instruksi (AGD-07).

## 6. Kompaksi konteks
Pemicu: token riwayat > 70% `maxContext`. Langkah: ringkas pesan lama menjadi `sessions.summary`
(LLM kecil), pertahankan N pesan terakhir + hasil tool penting; simpan pesan asli di DB (tetap bisa dicari).

## 7. Pencarian web
| Komponen | Pilihan | Status |
|---|---|---|
| Mesin utama | **SearXNG** self-host (AGPL-3.0; rolling release, build 2026.10.24) | ✅ aktif |
| Cadangan berbayar/terkelola | Tavily (`tavily_dart`, bagian monorepo langchain_dart) | ⚠️ cek versi |
| Instans publik SearXNG | **Jangan diandalkan** (banyak menonaktifkan JSON, balas 403) | ❌ |
| Ekstraksi halaman | `http` + `html` + pembersih (readability sederhana) | ⚠️ cek versi |

Aktifkan JSON di `settings.yml` SearXNG (default hanya `html`):
```yaml
search:
  formats: [html, json]
```
Uji: `curl "http://127.0.0.1:8080/search?q=test&format=json"`. Bind ke `127.0.0.1` saja.
Contoh Compose (image `docker.io/searxng/searxng:latest`, port lokal) mengikuti dokumentasi proyek.

Pipeline `web_search`: query → SearXNG (kategori general/news) → dedup URL → (opsional) fetch top-3 →
ekstrak teks → ringkas dengan LLM kecil → sitasi URL. Cache hasil di `kv` (TTL 1 jam untuk berita, 24 jam lainnya).
Proteksi SSRF: tolak IP privat/loopback/link-local, batasi redirect (≤ 3), ukuran respons (≤ 2 MB), tipe konten.

## 8. RAG dokumen pribadi
Chunking 500–800 token, overlap 10–15%, simpan `source_path` + posisi. Embedding multibahasa (lihat AGD-02).
Ingest tambahan inkremental berdasarkan hash file. Query memakai retrieval hibrida di atas.

## 9. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-04-01 | Skema drift + migrasi + WAL | Tes migrasi naik/turun |
| TASK-04-02 | FTS5 pada pesan dan memori | Tes pencarian bahasa Indonesia |
| TASK-04-03 | `VectorIndex` brute-force + tes performa 50k vektor | < 150 ms per query di target |
| TASK-04-04 | Tes `sqlite-vec` di Linux/Termux/Android | Laporan kompatibilitas |
| TASK-04-05 | SearXNG + tool `web_search`/`web_fetch` + SSRF guard | Tes blok IP privat |
| TASK-04-06 | Pipeline memori (tulis, dedup, peluruhan, `/memory`) | Tes kebijakan bagian 5 |
