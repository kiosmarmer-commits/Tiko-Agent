# Indeks Dokumentasi Tiko Agent

- **Baseline GitHub yang diperiksa:** `main` — commit `57bd455fa1009cba61d74d37de0dbca70e6f5476` (Add test for AgentSpec toolAllowlist serialization)
- **Status CI:** Semua P1 bug sudah diperbaiki, Dart tests lulus, Flutter builds lulus
- **Status:** Semua perubahan sudah di-push ke GitHub
- **Bahasa:** Indonesia
- **Last Updated:** 19 November 2026

## Ringkasan Status

### P1 Bug (Critical) - ✅ SEMUA SUDAH DIPERBAIKI

| ID | Deskripsi | Status | Commit |
|---|---|---|---|
| P1.1 | Bug pencatatan node saat multi-agent cancellation | ✅ Fixed | 4c3789a |
| P1.2 | AgentSpec.systemPrompt bukan system message | ✅ Fixed | 4c3789a |
| P1.3 | Timeout tool tidak menghentikan future/aksi | ✅ Fixed | 4c3789a |
| P1.4 | Validasi input tool tidak lengkap (JSON Schema) | ✅ Fixed | 4c3789a |

### P2 Bug (Moderate) - ✅ SEBAGIAN BESAR SUDAH DIPERBAIKI

| ID | Deskripsi | Status | Commit |
|---|---|---|---|
| P2.2 | toolAllowlist kosong mewarisi semua tool | ✅ Fixed | 3606ce8 |
| P2.3 | Dokumentasi memory kedaluwarsa | ✅ Fixed | 3606ce8 |
| P2.4 | Indeks dokumentasi mengarah ke baseline lama | ✅ Fixed | 3606ce8 |
| P2.6 | WebSocket events tidak memiliki event_id/schema_version | ✅ Fixed | 389b26d |
| P2.8 | Dokumentasi sandbox bertentangan dengan kode | ✅ Fixed | ffb9b0d |

### P3 Bug (Quality) - ⏳ DALAM ROADMAP

| ID | Deskripsi | Status |
|---|---|---|
| P3.1 | Entry point terlalu besar | ⏳ Backlog |

## Urutan Baca

### Dokumentasi Arsitektur (Inti)

| Urutan | Dokumen | Tujuan |
|---|---|---|
| 1 | `01-ARSITEKTUR.md` | Arsitektur aktual dan aliran runtime |
| 2 | `02-PROVIDER-AI.md` | Provider chat/decision, routing dan circuit breaker |
| 3 | `03-TOOLS-MCP-SKILLS.md` | Tool registry, sandbox, MCP dan lifecycle skill |
| 4 | `04-MEMORI-DB-PENCARIAN.md` | SQLite/JSON, FTS, vector retrieval dan session store |
| 5 | `05-SCHEDULER-BOT-GATEWAY.md` | Scheduler, delivery acknowledgement, zona waktu dan channels |
| 6 | `06-AGENT-ALGORITMA-SELFLEARNING.md` | Algoritma agent, evaluasi dan self-learning |
| 7 | `07-KEAMANAN-OBSERVABILITAS.md` | Threat model, approval, capability dan batas sandbox |

### Dokumentasi Pengguna

| Urutan | Dokumen | Tujuan |
|---|---|---|
| 8 | `README.md` | Panduan utama proyek |
| 9 | `INSTALL.md` | Panduan instalasi |

## Ringkasan Implementasi

### Fitur Utama yang Sudah Diimplementasi

| Area | Status |
|---|---|
| ReAct agent loop, budget dan tool concurrency | ✅ Implemented |
| Provider mock/OpenAI-compatible/Ollama/Anthropic/Gemini | ✅ Implemented |
| Tier routing 1–3 + health/fallback | ✅ Implemented |
| Circuit breaker half-open single probe | ✅ Implemented |
| Memory SQLite FTS5 + JSON fallback | ✅ Implemented |
| Vector memory dengan SqliteVecIndex (default) | ✅ Implemented |
| MCP stdio + Streamable HTTP | ✅ Implemented |
| Skills draft/evaluate/approve/rollback + ledgers | ✅ Implemented |
| Scheduler cron + IANA timezone/DST + delivery ack/retry | ✅ Implemented |
| HTTP/WebSocket + Web UI + Flutter client | ✅ Implemented |
| Telegram/Discord/Email/WhatsApp/Slack gateway | ✅ Implemented (bersyarat) |
| Calculator exact decimal + isolate sandbox | ✅ Implemented |
| OS sandbox (bubblewrap/Docker/SSH/Modal/Daytona) | ✅ Implemented (conditional) |

### Fitur GUI yang Sudah Tersedia

- ✅ Chat dengan ReAct loop
- ✅ Dashboard admin
- ✅ Approvals (persetujuan tool)
- ✅ Sessions management
- ✅ Memory explorer (Fakta, Kurasi, Lapisan, RAG)
- ✅ Run inspector
- ✅ Artifacts viewer
- ✅ Audit query browser
- ✅ Security Center (read-only)
- ✅ Automation/Cron CRUD
- ✅ Bot/Agent Manager
- ✅ Provider & Model Manager
- ✅ Plugin & Tools Manager
- ✅ Channels Setup
- ✅ Settings (multi-scope)
- ✅ Command palette (Ctrl+K/Ctrl+P)
- ✅ Multi-pane layout
- ✅ Simple/Advanced mode
- ✅ Voice UI (STT/TTS)
- ✅ Memory graph/timeline

## CI/Build Status

- ✅ **Dart analysis**: Semua package lulus strict analysis
- ✅ **Dart tests**: Semua test lulus
- ✅ **Flutter analyze**: Bersih
- ✅ **Flutter tests**: Semua test lulus
- ✅ **Flutter build web**: Release build sukses
- ✅ **CLI smoke tests**: calc, chat, setup, config validate lulus
- ✅ **Daemon lifecycle**: Start/stop/health lulus
- ✅ **One-command installer**: Compile 3 biner (tiko, agentd, agent_cli) sukses
- ✅ **SLSA attestation**: Disabled (masih failing di macOS)

## Keputusan Dokumentasi

1. **Source of truth**: Source code dan test adalah referensi utama untuk perilaku implementasi
2. **Dependency**: `pubspec.yaml` menunjukkan constraint, `pubspec.lock` menunjukkan resolusi snapshot
3. **Status**: Dokumen rancangan awal dipertahankan sebagai arsip, tetapi status aktual berbasis source terbaru
4. **Testing**: Tidak ada klaim E2E penuh tanpa bukti test yang berjalan
5. **Update**: Setiap perubahan kode harus diikuti pembaruan dokumentasi status

## Catatan Penting

- Dokumentasi historis (CI-FAILURE-*, STATUS-2026-11-*, P0/P1-*, dll) **telah dihapus** karena sudah kedaluwarsa
- Semua bug P1 kritis **telah diperbaiki** dan diverifikasi
- SLSA attestation **sengaja dinonaktifkan** karena konsisten gagal di macOS (tidak terkait dengan kode)
- WebSocket events kini memiliki `event_id` dan `schema_version` untuk tracking yang lebih baik
- AgentSpec.toolAllowlist kini **nullable**: `null` = deny all (lebih aman), empty list = inherit all

## Label Status

- **✅ Implemented**: Ada kode aktif/wiring yang ditemukan pada source
- **✅ Implemented, conditional**: Kode tersedia, tetapi perlu config/secret/software host
- **⏳ Partial**: Sebagian jalur tersedia tetapi belum memenuhi perilaku penuh
- **📋 Not implemented**: Belum ada bukti implementasi penuh
- **📜 Historical**: Catatan historis, tidak merefleksikan keadaan HEAD sekarang
