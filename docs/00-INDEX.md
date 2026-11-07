# 00-INDEX — Rancangan Agent AI ala Hermes dengan Dart

- **ID dokumen:** AGD-00
- **Tanggal verifikasi dependensi:** 2026-11-04
- **Bahasa:** Indonesia
- **Pembaca sasaran:** pengembang (Popop) dan AI lain yang akan melanjutkan implementasi
- **Status:** rancangan v1 (belum ada kode)

## 1. Tujuan
Membangun agent AI otonom berbahasa Dart yang meniru kemampuan inti Hermes Agent (Nous Research):
tool calling, memori persisten, skill yang bisa dipelajari, scheduler, gateway multi-platform
(CLI/Telegram/dll.), subagent, dan integrasi MCP. Agent harus bisa memakai API AI, AI lokal,
model keputusan (Jev/Laya), dan custom script tools.

## 2. Urutan baca (untuk AI lain)
| Urutan | File | Isi |
|---|---|---|
| 1 | `00-INDEX.md` | Ringkasan, legenda, keputusan |
| 2 | `01-ARSITEKTUR.md` | Layer, interface Dart, struktur proyek |
| 3 | `02-PROVIDER-AI.md` | LLM provider, decision model, routing |
| 4 | `03-TOOLS-MCP-SKILLS.md` | Tool contract, MCP, skills |
| 5 | `04-MEMORI-DB-PENCARIAN.md` | SQLite, FTS5, vektor, web search |
| 6 | `05-SCHEDULER-BOT-GATEWAY.md` | Scheduler dan bot |
| 7 | `06-AGENT-ALGORITMA-SELFLEARNING.md` | Algoritma agent dan self-learning |
| 8 | `07-KEAMANAN-OBSERVABILITAS.md` | Threat model dan kontrol |
| 9 | `08-REGISTRI-DEPENDENSI.md` | Versi, status aktif, skrip verifikasi |
| 10 | `09-ROADMAP-TASKS.md` | Fase, task ID, kriteria selesai, risiko |

## 3. Legenda status dependensi
| Simbol | Arti |
|---|---|
| ✅ | Diverifikasi sesi ini (2026-11-04) lewat sumber web; versi dan aktivitas tercatat |
| ⚠️ | Belum diverifikasi sesi ini, atau aktivitas rendah/pra-v1; wajib cek ulang sebelum dipakai |
| ❌ | Hindari (tidak aktif atau tidak sesuai) |

> Penting: tanggal rilis berasal dari agregator (ecosyste.ms, pub.dev, dll.) dan bisa tertinggal
> beberapa hari. Sebelum menulis `pubspec.yaml`, jalankan skrip di `08-REGISTRI-DEPENDENSI.md`
> bagian 4 untuk membaca versi terbaru langsung dari pub.dev.

## 4. Keputusan utama (DEC)
| ID | Keputusan | Alasan singkat |
|---|---|---|
| DEC-01 | Arsitektur **daemon Dart (CLI/server) + klien Flutter** | Android membatasi eksekusi shell/binary; daemon jalan di Termux/Linux/VPS |
| DEC-02 | Inti agent **tanpa framework besar**; pakai klien API tipis (`openai_dart`, `ollama_dart`, `anthropic_sdk_dart`, `googleai_dart`) | Kontrol penuh, lock-in rendah |
| DEC-03 | Dua interface terpisah: `LlmProvider` (chat) dan `DecisionProvider` (keputusan bertipe) | Jev/Laya bukan model chat |
| DEC-04 | Satu adapter **OpenAI-compatible** untuk Ollama/LM Studio/OpenRouter/llama.cpp server | Mengurangi jumlah adapter |
| DEC-05 | **SQLite (drift) + FTS5** sebagai penyimpanan tunggal; vektor lewat interface `VectorIndex` dengan fallback Dart murni | `sqlite-vec` masih pra-v1 |
| DEC-06 | MCP lewat **stdio dulu**; Streamable HTTP menyusul setelah uji kompatibilitas spec 2026-07-28 | Dukungan SDK Dart untuk spec terbaru belum terverifikasi |
| DEC-07 | Pencarian web via **SearXNG self-host** (JSON diaktifkan), Tavily sebagai cadangan | Gratis, privat |
| DEC-08 | Self-learning = **skill + memori terkurasi + evaluasi offline**, bukan melatih ulang model | Realistis, aman |
| DEC-09 | Izin bertingkat, default-deny untuk shell/tulis file, audit log wajib | Prompt injection nyata |

## 5. Ringkasan bukti verifikasi (sesi 2026-11-04)
- **Hermes Agent:** MIT, mayoritas Python; fitur: 40+ tool, skills, memori, MCP, cron, subagent, gateway
  Telegram/Discord/Slack/WhatsApp/Signal; dukungan Termux. Sumber: README `NousResearch/hermes-agent`.
- **MCP:** revisi spesifikasi saat ini **2026-07-28** (stateless, tanpa handshake `initialize`),
  menggantikan 2025-11-25. Sumber: scalar.com/learn/mcp, dev.to (rilis 28 Juli 2026).
- **Dart:** SDK 3.13.x terlihat pada analisis pub.dev (pana).
- Detail per paket: lihat `08-REGISTRI-DEPENDENSI.md`.

## 6. Batasan dokumen
1. Tidak semua paket sempat diverifikasi; yang belum ditandai ⚠️.
2. Format request Jev (`state`, header auth) belum diverifikasi dari dokumen resmi `docs.typesafe.ai/api`.
3. Belum ada benchmark akurasi pada bahasa Indonesia untuk Laya/Nimble; wajib uji sendiri (TASK-02-05).
4. Perubahan cepat (spec MCP, versi paket) membuat dokumen ini cepat usang; ulangi verifikasi tiap bulan.
