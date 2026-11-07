# 06-AGENT-ALGORITMA-SELFLEARNING

- **ID dokumen:** AGD-06
- **Bergantung pada:** AGD-01..AGD-05

## 1. Katalog algoritma agent
| ID | Algoritma | Fungsi | Kapan dipakai | Catatan implementasi |
|---|---|---|---|---|
| ALG-01 | **ReAct** (pikir → aksi → amati) | Loop dasar tool calling | Default | Batas iterasi, deteksi loop |
| ALG-02 | **Plan-and-execute** | Buat rencana langkah, eksekusi bertahap | Tugas multi-langkah | Rencana disimpan, bisa direvisi |
| ALG-03 | **Reflection/critic** | Periksa hasil sebelum dikirim | Tugas berisiko/kualitas | Satu putaran kritik, bukan tak terbatas |
| ALG-04 | **Subagent paralel** | Pecah tugas independen | Riset/pencarian banyak sumber | `Isolate` Dart atau future paralel; anggaran token terpisah; kedalaman maks 2 |
| ALG-05 | **Context compaction** | Ringkas riwayat | Konteks > 70% | Lihat AGD-04 §6 |
| ALG-06 | **Router bertingkat** | Pilih tier model | Setiap tugas | Lihat AGD-02 §2 |
| ALG-07 | **RRF + rerank** | Retrieval hibrida | Memori/RAG | Lihat AGD-04 §4 |
| ALG-08 | **Retry backoff + jitter** | Ketahanan API | Error 429/5xx/timeout | `delay = min(cap, base·2^n) · rand(0.5..1.0)` |
| ALG-09 | **Circuit breaker** | Hindari provider rusak | Kegagalan beruntun | 3 gagal → buka 60 dtk |
| ALG-10 | **Budget guard** | Batasi token/biaya/waktu | Selalu | Hentikan + laporkan saat melewati batas |
| ALG-11 | **Loop detector** | Cegah pengulangan | Selalu | Hash (tool, args); ≥3 kali identik berturut-turut → stop |
| ALG-12 | **Self-consistency (opsional)** | Voting beberapa sampel | Keputusan penting | Mahal; pakai hanya bila perlu |

### Detail ALG-11 (loop detector)
```dart
bool isLooping(List<ToolCall> recent) {
  if (recent.length < 3) return false;
  final last = recent.takeLast(3).map((c) => '${c.name}:${c.argsHash}').toSet();
  return last.length == 1; // tiga panggilan identik berturut-turut
}
```

### Detail ALG-10 (budget guard)
Parameter per tugas: `maxIterations`, `maxTokens`, `maxWallClock`, `maxToolCalls`, `maxCostUsd` (jika API berbayar).
Hitung dari `usage` yang dikembalikan provider; jika tidak tersedia, estimasi (karakter/4) dan tandai `estimated`.

## 2. Mekanisme self-learning (SL)
Prinsip DEC-08: tidak melatih ulang model; perilaku membaik lewat **data, skill, dan evaluasi**.
Hermes menggambarkan "closed learning loop" (skill otomatis setelah tugas kompleks, skill memperbaiki diri saat
dipakai, memori terkurasi, pencarian sesi lama). Berikut padanan yang aman untuk proyek ini.

| ID | Mekanisme | Pemicu | Keluaran | Gerbang keamanan |
|---|---|---|---|---|
| SL-01 | **Skill otomatis** | Tugas sukses dengan ≥ 4 tool call atau diulang ≥ 2× | `skills/<slug>/SKILL.md` status `draft` | Tidak aktif otomatis; masuk `trial` setelah user menyetujui |
| SL-02 | **Perbaikan skill** | Skill gagal/dikoreksi user | Versi baru + catatan kegagalan | Versi lama disimpan (rollback) |
| SL-03 | **Memori terkurasi** | Akhir turn | Fakta/preferensi di `memories` | Kebijakan tulis AGD-04 §5 |
| SL-04 | **Umpan balik** | 👍/👎 atau koreksi | Baris `feedback` | Dipakai untuk SL-05/SL-06 |
| SL-05 | **Few-shot dinamis** | Tugas baru mirip tugas sukses | 1–3 contoh dimasukkan ke prompt | Hanya contoh berumpan balik positif |
| SL-06 | **Evaluasi offline (golden tasks)** | Sebelum menerima perubahan prompt/skill/model | Skor lulus/gagal | Perubahan diterima hanya jika skor tidak turun |
| SL-07 | **Kalibrasi router** | Mingguan | Ambang baru untuk Decision | Ubah ambang hanya jika evaluasi membaik |
| SL-08 | **Kumpulan trajektori (lanjutan)** | Tugas sukses terverifikasi | Dataset JSONL untuk fine-tuning model kecil | Opt-in; hapus data sensitif |

### Siklus hidup skill (SL-01/02)
```
draft ──(user setuju)──► trial ──(≥5 pakai, sukses ≥ 80%)──► approved
   ▲                        │ gagal berulang                      │ sukses < 60% atau usang
   └──── revisi (SL-02) ◄───┴──────────────────────────────────── retired
```
Metrik per skill: `uses`, `successes`, `last_used_at` (tabel `skills`). "Sukses" = user tidak mengoreksi + tidak ada error tool
+ (opsional) penilaian Noul "apakah tujuan tercapai?".

### Pembuat skill (prompt kerangka)
Masukan: transkrip turn + tool call + hasil. Keluaran wajib: `name`, `description`, `triggers`, `tools`, langkah
bernomor, bagian "Kegagalan umum". Validasi kode: frontmatter valid, tool yang disebut ada di registry,
panjang ≤ 4 KB, **tanpa kredensial/path pribadi** (regex), tidak memuat perintah yang menaikkan izin.

## 3. Evaluasi (SL-06)
- **Golden tasks:** `test/golden/*.yaml` berisi `input`, `tools_dibolehkan`, `kriteria` (cek otomatis: tool yang dipanggil,
  substring/regex jawaban, penilaian Noul), `bobot`.
- Jalankan dengan provider tiruan + (opsional) model lokal nyata; simpan hasil di `eval_runs` (versi prompt, model, skor).
- **Aturan regresi:** perubahan prompt/skill/model ditolak jika skor total turun > 2 poin atau ada kegagalan pada tugas
  kategori keamanan.
- Sertakan set khusus Indonesia (router/guardrail 50 kalimat; TASK-02-05) dan set serangan injeksi (AGD-07).

## 4. Metrik yang dicatat
| Metrik | Satuan | Tujuan |
|---|---|---|
| success_rate | % | Kualitas tugas |
| avg_iterations, avg_tool_calls | angka | Efisiensi |
| tokens_in/out, cost | angka | Biaya |
| p50/p95 latency | detik | Pengalaman |
| router_accuracy | % | Kualitas keputusan T1 |
| memory_hit_rate | % | Manfaat memori |
| skill_success_rate | % | Kualitas skill |
| confirm_rate | % | Seberapa sering izin diminta |

## 5. Task
| ID | Task | Kriteria selesai |
|---|---|---|
| TASK-06-01 | ReAct loop + budget guard + loop detector | Tes batas dan loop |
| TASK-06-02 | Compactor + tes kualitas ringkasan | Fakta kunci tetap ada |
| TASK-06-03 | Subagent paralel dengan anggaran terpisah | Tes 3 subagent paralel |
| TASK-06-04 | Pembuat skill `draft` + validator | Skill valid dihasilkan dari transkrip uji |
| TASK-06-05 | Harness golden tasks + aturan regresi | CI menolak regresi |
| TASK-06-06 | Umpan balik 👍/👎 + few-shot dinamis | Contoh relevan muncul di prompt |
