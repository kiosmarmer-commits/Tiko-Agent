# Indeks Dokumentasi Tiko-Agent

**Source snapshot:** commit `ddb7ceb` pada branch `main`.

**Terakhir diperbarui:** 20 November 2026.

**Aturan status:** source code dan test adalah bukti utama. “Tersedia sebagai library” tidak sama dengan “terhubung ke runtime/user command”. Status CI harus dibaca dari [GitHub Actions](https://github.com/kiosmarmer-commits/Tiko-Agent/actions).

## Urutan baca

| Urutan | Dokumen | Fokus |
|---|---|---|
| 1 | [INSTALL.md](../INSTALL.md) | Instalasi dan operasi |
| 2 | [01-ARSITEKTUR.md](01-ARSITEKTUR.md) | Package graph dan aliran runtime |
| 3 | [02-PROVIDER-AI.md](02-PROVIDER-AI.md) | Provider, routing, health, circuit breaker |
| 4 | [03-TOOLS-MCP-SKILLS.md](03-TOOLS-MCP-SKILLS.md) | Tool registry, sandbox, MCP, skills |
| 5 | [04-MEMORI-DB-PENCARIAN.md](04-MEMORI-DB-PENCARIAN.md) | Store, FTS, vector, RAG |
| 6 | [05-SCHEDULER-BOT-GATEWAY.md](05-SCHEDULER-BOT-GATEWAY.md) | Scheduler, bot, gateway, delivery |
| 7 | [06-AGENT-ALGORITMA-SELFLEARNING.md](06-AGENT-ALGORITMA-SELFLEARNING.md) | Loop, evaluasi, self-learning |
| 8 | [07-KEAMANAN-OBSERVABILITAS.md](07-KEAMANAN-OBSERVABILITAS.md) | Security dan telemetry |
| 9 | [08-PEDOMAN-PENGEMBANGAN.md](08-PEDOMAN-PENGEMBANGAN.md) | Prosedur perubahan aman |
| 10 | [09-DESAIN-GUI.md](09-DESAIN-GUI.md) | Token UI, gaya flat modern, paritas lintas platform |
| 11 | [10-WEB-UI.md](10-WEB-UI.md) | Dashboard web agentd (Flutter Web), sesi cookie, auto-open |
| 12 | [12-HERMES-FITUR-BERIKUTNYA.md](12-HERMES-FITUR-BERIKUTNYA.md) | Pemetaan fitur Hermes → Tiko (discovery, hooks, cron, dsb.) |

## Status implementasi

| Area | Status | Batasan penting |
|---|---|---|
| Agent loop, cancellation, budget, tool orchestration | Implemented | Perubahan harus menjaga contract test agent_core |
| Provider AI, routing, health, circuit breaker | Implemented/conditional | Memerlukan endpoint dan secret provider |
| Memory SQLite/JSON, FTS, vector, RAG, layers | Implemented/conditional | SQLite native tidak selalu tersedia; JSON fallback degraded |
| Tools, sandbox, MCP stdio/HTTP, OAuth | Implemented/conditional | Sandbox OS dan secret dapat membuat capability unavailable |
| Browser CDP lokal/remote | Implemented/conditional | Chrome atau backend remote harus tersedia |
| Scheduler dan job delivery | Implemented | Channel tujuan harus aktif |
| Telegram/Discord/Slack/WhatsApp/Email/Signal/Matrix/LINE | Implemented/conditional | Masing-masing membutuhkan konfigurasi dan credential |
| Teams | Implemented | Outbound webhook dan inbound Bot Framework activity melalui `/webhooks/teams` dengan bearer token |
| ACP resources | Implemented | List/read/write resource terdaftar, resource read-only, dan command fail-closed |
| Wake-word Porcupine/openWakeWord | Partial | Native engine belum terhubung; tersedia fallback energy/keyword |
| Event Hooks (Hermes-parity P1) | Implemented | Config `hooks:` (event/webhook/script); hasil di `hook.executed` + snapshot `/v1/plugins`; GUI settings menyusul |
| Home Assistant provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| Tuya provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| SONOFF/eWeLink CUBE provider | Implemented as library | User-facing smart-home tool/runtime wiring belum lengkap |
| Google Home | Conditional via Home Assistant | Tidak ada direct Google Home API provider di repo |
| Self-learning/reflection | Implemented with guards | Sintesis tetap dibatasi gate, score, dan approval |
| Flutter client/widgets | Implemented/conditional | Memerlukan Flutter SDK dan daemon/API |
| Web dashboard agentd (Jalur A) | Implemented/conditional | Flutter Web sebagai satu-satunya webRoot + cookie sesi same-origin + auto-open browser; butuh `flutter build web` sebelum daemon dapat menyajikan UI |
| Simpul vault/index | Implemented | Modul terpisah dari agent runtime utama |

## Kontrak dokumentasi

- Setiap fitur publik harus punya lokasi source, entry point, konfigurasi, batasan, dan test yang dapat ditemukan.
- Algoritma yang memengaruhi score, ranking, routing, prediksi, memory retention, atau approval harus didokumentasikan bersama invariant dan fixture regresinya.
- Klaim “full”, “real-time”, “secure”, atau “production-ready” harus memiliki bukti test/integration yang sesuai; jika belum, gunakan label `Partial` atau `Conditional`.
- Dokumen historical boleh dipertahankan sebagai arsip, tetapi tidak boleh menjadi rujukan status HEAD tanpa label tanggal dan commit.

## Validasi terdokumentasi

Validasi lokal pada snapshot ini:

- `dart analyze packages/agent_tools packages/agent_gateway apps/agentd --fatal-warnings`: tidak ada error/warning fatal; tersisa info lint nonfatal.
- OAuth dan smart-home tests: lulus.
- `agent_core`, `agent_memory`, dan `agent_tools`: lulus dengan dua random-order seeds.
- `tiko_runtime`: suite lokal sangat lambat dan tidak selesai dalam sesi audit; status final mengikuti CI remote.

## Label status

- **Implemented** — kode aktif, wiring, dan test kontrak tersedia.
- **Implemented/conditional** — kode dan wiring tersedia, tetapi environment/credential diperlukan.
- **Implemented as library** — API provider tersedia, tetapi belum otomatis menjadi command/runtime feature.
- **Partial** — jalur utama tersedia, tetapi ada bagian penting yang belum terpenuhi.
- **Not implemented** — belum ada bukti source/test yang memadai.
- **Historical** — catatan lama; tidak merepresentasikan HEAD sekarang.
