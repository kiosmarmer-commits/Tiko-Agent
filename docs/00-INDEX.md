# Indeks Dokumentasi Tiko Agent

- **Baseline GitHub yang diperiksa:** `main` — `dfa7a0ecbd830fd9ecaa50f37145bb27351f5711` (`fix bug build error`).
- **CI baseline:** run [42687414796](https://github.com/kiosmarmer-commits/Tiko-Agent/actions/runs/42687414796) berhasil pada kedua job (Dart workspace/CLI dan Flutter/Web).
- **Bundle implementasi lanjutan:** perubahan provider routing, SMTP timeout, MCP GET SSE/protocol header/config, regression tests dan dokumentasi di atas baseline `dfa7a0e`; perubahan ini belum dikirim ke GitHub dan belum tervalidasi Dart/Flutter karena SDK tidak tersedia di lingkungan penyusunan.
- **Status:** CI hijau hanya membuktikan baseline `dfa7a0e`, bukan bundle lanjutan. Gunakan `STATUS-2026-11-10.md` sebagai sumber status terkini bundle.
- **Bahasa:** Indonesia.

## Urutan baca

| Urutan | Dokumen | Tujuan |
|---|---|---|
| 1 | `CI-FAILURE-2026-11-10.md` | Histori insiden CI SMTP pada run 42678040519 dan tautan ke status run perbaikan |
| 2 | `STATUS-2026-11-10.md` | Status baseline CI dan bundle lokal yang belum lolos Dart/Flutter gate |
| 3 | `P1-ROBUSTNESS-2026-11-10.md` | Detail hardening concurrency, trust, MCP, SMTP, Flutter dan provider-routing follow-up |
| 4 | `STATUS-2026-11-09.md` | Status historis baseline |
| 5 | `REPOSITORY-AUDIT-2026-11-09.md` | Bukti audit kode-vs-dokumen |
| 6 | `01-ARSITEKTUR.md` | Arsitektur aktual dan aliran runtime |
| 7 | `02-PROVIDER-AI.md` | Provider chat/decision, routing dan circuit breaker |
| 8 | `03-TOOLS-MCP-SKILLS.md` | Tool registry, sandbox, MCP dan lifecycle skill |
| 9 | `04-MEMORI-DB-PENCARIAN.md` | SQLite/JSON, FTS, vector retrieval dan session store |
| 10 | `05-SCHEDULER-BOT-GATEWAY.md` | Scheduler, delivery acknowledgement, zona waktu dan channels |
| 11 | `06-AGENT-ALGORITMA-SELFLEARNING.md` | Algoritma agent, evaluasi dan self-learning |
| 12 | `07-KEAMANAN-OBSERVABILITAS.md` | Threat model, approval, capability dan batas sandbox |
| 13 | `08-REGISTRI-DEPENDENSI.md` | Dependency manifest dan toolchain CI aktual |
| 14 | `09-ROADMAP-TASKS.md` | Backlog berbasis gap yang masih nyata |
| 15 | `email-smtp.md` | Status SMTP outbound, STARTTLS verification/no-downgrade dan input validation |
| 16 | `sqlite-vec-notes.md` | Catatan riset; belum menjadi runtime backend |
| 17 | `ADVANCED-AGENT-FEATURES-2026-11-10.md` | Reflection loop, Advanced RAG, multi-agent orchestration, content-plane security guard, layered memory |
| 18 | `HERMES-PARITY-GAPS-2026-11-10.md` | Plugins system, memory providers eksternal, prompt caching, API server OpenAI-compatible, ACP IDE, cloud browser backends, Discord voice, image/TTS breadth, agentskills.io + Skills Hub |

`README.md` dan `INSTALL.md` adalah panduan pengguna. Dokumen arsitektur `01-08` dan `dependency-log.md` awalnya direkonsiliasi terhadap snapshot lama; dokumen tersebut adalah referensi desain/implementasi, bukan bukti CI untuk bundle implementasi lokal. Gunakan `STATUS-2026-11-10.md` dan `P1-ROBUSTNESS-2026-11-10.md` untuk status kerja terkini. Laporan `CALC-*` adalah milestone calculator bertanggal 8 November. `P0/P1-*`, `TIKO-*`, `PERBAIKAN-*`, `STATUS-2026-11-09.md`, dan `REPOSITORY-AUDIT-2026-11-09.md` dipertahankan sebagai arsip/historis; jangan menggunakannya sebagai status sekarang. Laporan fitur `*-2026-11-09.md` mencatat patch saat itu; baca bersama source karena kontrak dapat berubah setelah commit laporan.

## Label status

- **Implemented**: ada kode aktif/wiring yang ditemukan pada source snapshot.
- **Implemented, conditional**: kode tersedia, tetapi perlu config, secret, software host, atau provider tertentu.
- **Partial**: sebagian jalur tersedia tetapi belum memenuhi perilaku penuh/production release.
- **Not implemented / open**: belum ada bukti implementasi penuh pada snapshot.
- **Historical**: catatan saat commit/tanggal yang tertulis; tidak boleh dibaca sebagai keadaan HEAD sekarang.

## Ruang lingkup source yang diaudit

Monorepo root `pubspec.yaml` memiliki workspace `agent_core`, `agent_calc`, `agent_providers`, `agent_tools`, `agent_memory`, `agent_gateway`, `agent_scheduler`, `agent_security`, `tiko_runtime`, `agentd`, `agent_cli`, dan `tiko`. `apps/agent_flutter` merupakan aplikasi Flutter terpisah dan diuji pada job CI tersendiri.

## Ringkasan implementasi

| Area | Kondisi pada snapshot |
|---|---|
| ReAct agent loop, budget dan tool concurrency | Implemented dengan opt-in parallelSafe pada delta lokal; belum tervalidasi Dart CI |
| Provider mock/OpenAI-compatible/Ollama native/Anthropic/Gemini | Implemented; koneksi/provider nyata butuh konfigurasi |
| Tier routing 1–3 + health/fallback | Implemented |
| Circuit breaker half-open single probe | Runtime aktif memakai `Router.ProviderHealth` sebagai satu pemilik state; fallback mengunci slot probe. Wrapper `agent_providers.CircuitBreaker` tetap legacy API dan tidak di-wire runtime |
| Memory SQLite FTS5 + JSON fallback | Implemented; backend tergantung kemampuan native host |
| Vector memory | Implemented melalui `BruteForceVectorIndex`; embedding opsional |
| MCP stdio + Streamable HTTP | Implemented; bundle terbaru menambahkan GET SSE opsional, protocol-version header/config, dengan request server-initiated ber-ID masih hanya dicatat |
| Skills draft/evaluate/approve/rollback + ledgers | Implemented |
| Scheduler cron + IANA timezone/DST + delivery ack/retry | Implemented di daemon integration |
| HTTP/WebSocket + Web UI + Flutter client | Implemented; uji visual perangkat nyata tetap perlu |
| Telegram/Discord/Email outbound/WhatsApp webhook/Slack webhook | Implemented bersyarat; SMTP timeout hardening ada pada bundle lokal; Email inbound belum di-wire ke daemon |
| Calculator exact decimal + isolate sandbox | Implemented |
| OS sandbox | Conditional; efektivitas bergantung host dan jenis sandbox |

## Keputusan dokumentasi

1. Source pada commit snapshot dan test adalah sumber kebenaran untuk perilaku implementasi.
2. `pubspec.yaml` menunjukkan dependency constraint langsung; `pubspec.lock` menunjukkan resolusi pada snapshot. Keduanya tidak sama dengan klaim “versi terbaru pub.dev”.
3. Dokumen rancangan awal tidak dihapus, tetapi status dan kontrak aktual dibedakan dari ide/roadmap awal.
4. Tidak ada klaim bahwa seluruh integrasi eksternal (server MCP vendor, akun Telegram/Discord/Slack/WhatsApp, layanan AI cloud) diuji end-to-end hanya karena mock test/CI lulus.
5. Perubahan kode setelah snapshot harus diikuti pembaruan status dan pengujian; jangan menyalin status CI lama ke commit baru.
