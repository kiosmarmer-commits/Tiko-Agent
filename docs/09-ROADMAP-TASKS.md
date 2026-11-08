# 09-ROADMAP-TASKS

- **ID dokumen:** AGD-09
- **Bergantung pada:** AGD-00..AGD-08

## 1. Fase (M)
| Fase | Tujuan | Isi (task) | Kriteria selesai (DoD) | Estimasi* |
|---|---|---|---|---|
| **M0** | Fondasi | TASK-01-01..03, TASK-08-01 | Workspace, interface, loop dengan provider tiruan, `dart analyze` bersih | 2–3 hari |
| **M1** | Agent minimal | TASK-02-01, 03-01..03, 05-01, 07-01 | CLI + Ollama lokal + 3 tool (read_file, web_fetch, shell ber-izin) berjalan | 1 minggu |
| **M2** | Memori | TASK-04-01..03, 04-06 | Riwayat tersimpan, FTS5, memori semantik brute-force, `/memory` | 1 minggu |
| **M3** | Pencarian | TASK-04-05, 03-04 | SearXNG + `web_search`; klien MCP stdio terhubung ke ≥ 2 server | 1 minggu |
| **M4** | Bot + scheduler | TASK-05-02..04, 07-02..03 | Telegram dengan allowlist + konfirmasi; job terjadwal dengan missed policy | 1 minggu |
| **M5** | Router/keputusan | TASK-02-02, 02-04, 02-05 | DecisionProvider (Laya/Jev/fallback) + evaluasi Indonesia | 1 minggu |
| **M6** | Self-learning | TASK-06-01..06 | Skill `draft→trial→approved`, golden tasks, regresi di CI | 2 minggu |
| **M7** | Klien Flutter + hardening | TASK-05-05, 07-04..06, 04-04 | UI via WebSocket, suite SEC-01..08 hijau, uji `sqlite-vec` | 2 minggu |
\*Estimasi kasar untuk satu pengembang paruh waktu; sesuaikan.

## 2. Daftar task lengkap
| ID | Task | Fase | Dok |
|---|---|---|---|
| TASK-01-01 | Workspace + paket kosong | M0 | AGD-01 |
| TASK-01-02 | Interface inti | M0 | AGD-01 |
| TASK-01-03 | Agent loop + provider tiruan | M0 | AGD-01 |
| TASK-02-01 | Adapter OpenAI-compat | M1 | AGD-02 |
| TASK-02-02 | Verifikasi `/v1/systemone` | M5 | AGD-02 |
| TASK-02-03 | Adapter Anthropic/Gemini | M5 | AGD-02 |
| TASK-02-04 | Circuit breaker + fallback | M5 | AGD-02 |
| TASK-02-05 | Set evaluasi Indonesia (50 kalimat) | M5 | AGD-02 |
| TASK-03-01 | Registry + validasi skema | M1 | AGD-03 |
| TASK-03-02 | PermissionGate CLI | M1 | AGD-03 |
| TASK-03-03 | Script tool runner | M1 | AGD-03 |
| TASK-03-04 | Klien MCP stdio + tes spec | M3 | AGD-03 |
| TASK-03-05 | Loader skill | M6 | AGD-03 |
| TASK-04-01 | Skema drift + migrasi | M2 | AGD-04 |
| TASK-04-02 | FTS5 | M2 | AGD-04 |
| TASK-04-03 | VectorIndex brute-force | M2 | AGD-04 |
| TASK-04-04 | Tes sqlite-vec lintas target | M7 | AGD-04 |
| TASK-04-05 | SearXNG + web tools + SSRF guard | M3 | AGD-04 |
| TASK-04-06 | Pipeline memori | M2 | AGD-04 |
| TASK-05-01 | Kanal CLI + Gateway | M1 | AGD-05 |
| TASK-05-02 | Gateway Telegram | M4 | AGD-05 |
| TASK-05-03 | Scheduler | M4 | AGD-05 |
| TASK-05-04 | Tool `schedule_job` | M4 | AGD-05 |
| TASK-05-05 | API HTTP/WS untuk Flutter | M7 | AGD-05 |
| TASK-05-06 | Discord/Email (opsional) | M7 | AGD-05 |
| TASK-06-01..06 | Algoritma agent + self-learning | M6 | AGD-06 |
| TASK-07-01..06 | Keamanan + observabilitas | M1–M7 | AGD-07 |
| TASK-08-01..03 | Verifikasi dependensi | M0 + bulanan | AGD-08 |

## 2a. Track `agent_calc` (TASK-CALC)

Kalkulator eksak memakai penomoran TASK-CALC sendiri; status per
2026-11-08:

| Fase | Task | Status |
|---|---|---|
| CALC-M0 | TASK-CALC-01..08, 10..11 (09 sempat ditunda) | selesai — `CALC-M0-COMPLETE-2026-11-08.md` |
| CALC-M1 | TASK-CALC-12..20 satuan, keuangan, statistik, tanggal | selesai — `CALC-M1-COMPLETE-2026-11-08.md` |
| CALC-M2 | TASK-CALC-09 sandbox isolate + TASK-CALC-36 benchmark tool | selesai — `CALC-M2-TASK-09-36-COMPLETE-2026-11-08.md` |
| CALC-M3 | TASK-CALC-21..23 (inferensi): CalcTool via sandbox, golden M1, flag CLI `tiko calc` | selesai — `CALC-M3-INFERENCE-2026-11-08.md` + `CALC-CI-FIX-M3-TOOLS-2026-11-08.md` |
| — | TASK-CALC-24..35 | **menunggu definisi pemilik proyek** (tidak ada di repo) |
| — | Bagian device TASK-CALC-36 (benchmark Termux nyata) | menunggu perangkat fisik |

## 3. Register risiko (RISK)
| ID | Risiko | Peluang | Dampak | Mitigasi | Pemilik task |
|---|---|---|---|---|---|
| RISK-01 | `dart_mcp` belum mendukung MCP 2026-07-28 (stateless) | Sedang | Sedang | Interface `McpTransport`; klien JSON-RPC HTTP sendiri; mulai dari stdio | TASK-03-04 |
| RISK-02 | Format `/v1/systemone` berbeda dari asumsi | Sedang | Rendah | Verifikasi dengan `curl`; adapter terisolasi | TASK-02-02 |
| RISK-03 | Akurasi decision model rendah untuk bahasa Indonesia | Tinggi | Sedang | Evaluasi sendiri; ambang konservatif; fallback LLM; allowlist sebagai lapisan utama | TASK-02-05 |
| RISK-04 | Laya (Python+torch) berat di Termux/HP | Tinggi | Sedang | Jalankan di PC/VPS; coba varian ONNX; atau fallback LLM kecil via Ollama | TASK-02-05 |
| RISK-05 | `sqlite-vec` pra-v1: breaking change / gagal dimuat di Android | Sedang | Rendah | `VectorIndex` + brute-force default | TASK-04-04 |
| RISK-06 | Proses daemon dimatikan Android | Tinggi | Sedang | `termux-wake-lock`, layanan, atau VPS | TASK-05-03 |
| RISK-07 | Prompt injection berhasil memicu tool berbahaya | Sedang | Tinggi | AGD-07 C-01..C-04, uji SEC-01 | TASK-07-02 |
| RISK-08 | Lompatan versi mayor klien API (mis. 4.0, 9.0, 11.0, 13.0) mematahkan kode | Sedang | Sedang | Pin versi; adapter tipis; tes kontrak | TASK-02-01 |
| RISK-09 | Paket ⚠️ ternyata tidak aktif | Sedang | Rendah | Kriteria K-1..K-6; alternatif sudah dicatat | TASK-08-01 |
| RISK-10 | Skill otomatis menurunkan kualitas | Sedang | Sedang | Status `draft/trial`; golden tasks; rollback | TASK-06-05 |
| RISK-11 | Biaya API membengkak | Rendah | Sedang | ALG-10, mode `local_only` | TASK-06-01 |
| RISK-12 | Tidak ada PC untuk debugging | Tinggi | Sedang | Daemon dapat dites lewat CLI di Termux; log ke file; klien Flutter belakangan | M0–M1 |

## 4. Pertanyaan terbuka (OQ)
| ID | Pertanyaan | Perlu keputusan oleh |
|---|---|---|
| OQ-01 | Target utama: Termux di HP, VPS, atau PC? (menentukan sandbox dan pilihan Laya) | Pengguna |
| OQ-02 | Apakah memakai API cloud (Anthropic/OpenAI/Gemini) atau murni lokal? | Pengguna |
| OQ-03 | Kanal wajib: Telegram saja, atau juga Discord/Email/WhatsApp? | Pengguna |
| OQ-04 | Perlu fitur suara (STT/TTS) pada versi pertama? | Pengguna |
| OQ-05 | Maksud "Jev AI" pada awal diskusi sudah dikonfirmasi = TypeSafe AI Jev (model keputusan) | Selesai |
| OQ-06 | Skala memori: ≤ 50 ribu vektor cukup? | Pengguna |

## 5. Instruksi untuk AI pelaksana
1. Kerjakan **satu task ID per sesi** dan jangan melompati fase.
2. Sebelum menulis `pubspec.yaml`, jalankan skrip AGD-08 §4 dan catat hasilnya.
3. Setiap task harus menyertakan tes dan kriteria selesai dari dokumennya.
4. Pecah pekerjaan besar menjadi file kecil, simpan setiap file segera, dan catat progres agar sesi berikutnya dapat
   melanjutkan tanpa mengulang.
5. Laporkan temuan dalam format: `ID | path file | bukti | saran perbaikan`.
6. Jangan menambahkan dependensi baru tanpa mencatatnya di AGD-08 dengan status verifikasi.

## 6. Langkah pertama yang disarankan (hari ini)
1. Pilih target (OQ-01) lalu jalankan skrip verifikasi dependensi (TASK-08-01).
2. Pasang Ollama (atau server OpenAI-compatible lain) dan uji `curl http://127.0.0.1:11434/v1/chat/completions`.
3. Mulai M0: `dart create` untuk `agent_core`, tulis interface bagian 5 AGD-01, dan uji loop dengan provider tiruan.
