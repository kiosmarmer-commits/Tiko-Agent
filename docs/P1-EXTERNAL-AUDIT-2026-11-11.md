# Perbaikan P1 — Audit Eksternal (2026-11-11)

Basis: backlog P1 dari laporan audit eksternal (laporan ChatGPT) terhadap commit `cc57486`. Enam item diverifikasi terhadap source sebelum dikerjakan.

## Ringkasan item

| ID | Temuan | Status verifikasi | Perbaikan |
|----|--------|-------------------|-----------|
| P1-1 | Subagent telemetry: `tokenCount` diestimasi `text.length ~/ 4`; `toolCallCount` selalu 0; cost 0 | Valid | `ChatRunResult` diperluas dengan `tokensUsed`, `toolCallCount`, `toolCallTraces` (diisi dari `AgentLoop.lastTokensUsed`/`lastToolCalls` di `chatWithStatus()`). Runner subagent memakai telemetry asli, bukan estimasi |
| P1-2 | OpenAI-compatible API dan ACP belum penuh di-wire; ACP tidak mendukung `session/load` | Sebagian stale — server OpenAI-compat sudah di-wire ke agentd via `OPENAI_API_PORT`; yang belum ada `session/load` + ACP di daemon | `AcpDispatcher` kini mendukung `session/load` (loader opsional → riwayat direplay sebagai `session/update` `user_message_chunk`/`agent_message_chunk`; `initialize` mengiklankan `loadSession: true` bila loader diinjeksi). ACP di-wire ke daemon agentd melalui `--acp` / `TIKO_ACP=1` (stdio, session loader membaca `SessionStore`); CLI `tiko acp` juga mendapat loader yang sama |
| P1-3 | Belum ada e2e test layanan eksternal dengan mock server | Sebagian valid — MCP stdio/HTTP/OAuth, browser, image, cloud sandbox, Mem0/Honcho, Signal/Matrix, TTS sudah tercover test loopback; yang belum: LLM API dan gateway Telegram/Discord/Slack/WhatsApp | Test e2e baru: `openai_compat_e2e_test.dart` (mock server OpenAI: non-stream, streaming SSE + usage, tool call parsing, HTTP 500 → `LlmError` berkode status) dan `external_gateways_e2e_test.dart` (Telegram send + long-polling inbound + default-deny allowlist, Discord bot send, Slack `chat.postMessage`, WhatsApp Meta graph send) — semua lewat HTTP nyata ke mock loopback. CI ditambah trigger `schedule` mingguan |
| P1-4 | Discord voice belum punya enkripsi `xsalsa20_poly1305` yang diuji | Valid — `UnsupportedVoiceEncryptor` hanya throw | Implementasi secretbox NaCl pure-Dart (`nacl_secretbox.dart`: XSalsa20 + Poly1305 via BigInt, tanpa dependency baru), terverifikasi terhadap test vector PyNaCl/libsodium. `DiscordVoiceClient` menyimpan `secret_key` op 6, nonce = RTP header 12 byte + 12 zero (format `xsalsa20_poly1305`), payload opus disegel; roundtrip + tamper detection teruji |
| P1-5 | Skor hit Mem0/Honcho/local diurutkan mentah lintas skala | Valid | `_FanoutMemoryStore.search()` kini memakai Reciprocal Rank Fusion (`rrfK = 60`) dengan dedup by id (local menang tie), bukan sort skor mentah |
| P1-6 | Tidak ada evaluation harness yang konsisten | Valid | `EvalHarness` di `agent_core` (`eval_harness.dart`): 8 keluarga metrik — task completion, golden correctness, tool precision, tool error rate, recovery, injection resistance, memory recall, team overhead (vs baseline token) — plus deteksi regresi antar-run (`regressionsVs`) dan ekspor JSON. Di-wire ke CLI: `tiko eval <cases.json> [--label L]` menjalankan suite lewat `rt.chatWithStatus()` dan menyimpan laporan ke `<dataDir>/eval/` |

## Batasan yang dicatat

- Cost subagent tetap `0.0`: tidak ada tabel harga per model di repo; token usage asli kini tercatat, konversi ke rupiah/dolar menunggu pricing table.
- Cancellation subagent tetap memakai wall-clock budget (`AgentConfig.maxWallClockSec`); cancellation token kooperatif per-tool belum ada.
- Enkripsi voice mencakup mode `xsalsa20_poly1305` (wajib Discord); mode `aead_xchacha20_poly1305` kini **tuntas** — lihat `DEFERRED-COMPLETION-2026-11-12.md`.
- Filesystem/permission surface ACP (`fs/read_text_file`, `fs/write_text_file`) belum diimplementasikan — butuh kontrak permission request ke client editor.
- Test e2e eksternal memakai mock loopback; akun sandbox nyata (Telegram/Discord/Slack/Meta) tetap butuh secret CI dan tidak dibuat otomatis.

## Tes

- `packages/agent_core/test/eval_harness_test.dart`: 6 kasus (metrik per keluarga, overhead vs baseline, exception runner, regresi antar-run, JSON roundtrip).
- `packages/agent_providers/test/openai_compat_e2e_test.dart`: 4 kasus e2e mock server.
- `packages/agent_gateway/test/external_gateways_e2e_test.dart`: 6 kasus e2e mock loopback.
- `packages/agent_gateway/test/discord_voice_test.dart`: test vector PyNaCl (33 byte + pesan kosong), roundtrip + tamper, seal `sendOpusFrame` dengan secret key op 6.
- `packages/agent_tools/test/acp_agent_test.dart`: +3 kasus (`session/load` replay, `initialize` mengiklankan `loadSession`, tanpa loader → `-32601`).
- Full suite: 10 workspace member hijau (agent_calc 132, agent_core 113, agent_gateway 51, agent_memory 80, agent_providers 29, agent_scheduler 35, agent_security 55, agent_tools 215, tiko_runtime 99, agentd 1).
