# Paritas Hermes — Penutupan P1-7 s/d P1-10: 11 November 2026

**Status:** Implemented + unit/integration test, divalidasi lokal (`dart analyze` + `dart test` semua package) sebelum push. Basis: HEAD `afc4cb5`.

Dokumen ini melengkapi `HERMES-PARITY-GAPS-2026-11-10.md` dan backlog §7 P1
laporan audit menyeluruh: item 7 (session search), 8 (bukti closed-loop
skill), 9 (MCP HTTP lifecycle), 10 (happy-path terdokumentasi).

## P1-7 — Session search lintas percakapan

- **Kontrak:** `SessionStore.searchSessions(query, {limit})` di
  `packages/agent_core/lib/src/interfaces.dart` dengan default implementasi
  kosong (tidak mem-break implementor lain) + tipe `SessionSearchHit`
  (session id, role, snippet, score, title, timestamp).
- **Implementasi:** `FileSessionStore.searchSessions` — pencarian AND atas
  token query di semua pesan tersimpan (sudah ter-redaksi `SecretRedactor`),
  ranking term-frequency + bonus recency, snippet berjendela ±120 karakter.
- **Tool:** `session_search` (`packages/agent_tools/lib/src/session_search_tool.dart`)
  — output dalam envelope `untrusted_data` dengan escape delimiter, risk low.
- **Wiring:** `TikoRuntime.create()` mendaftarkan `SessionSearchTool(sessionStore)`.
- **Tes:** `packages/agent_memory/test/session_search_test.dart` (8 kasus:
  lintas sesi, semantik AND, ranking, snippet bounded, limit, empty query,
  konsistensi lintas proses, default interface) +
  `packages/agent_tools/test/session_search_tool_test.dart` (4 kasus end-to-end).

## P1-8 — Bukti closed-loop skill (golden test)

- **Wiring yang sebelumnya hilang:** `SelfLearningEngine.processTurn` tidak
  pernah dipanggil dari jalur chat. Kini `chatWithStatus` memanggil
  `_learnOnTurn` setelah tiap turn (trajectory + tool calls), dengan event
  `skill.synthesized` saat skill baru berhasil dibuat. Kegagalan sintesis
  tidak pernah menggagalkan turn.
- **Perbaikan loop:** `_parseSkillFromResponse` kini mem-parse `triggers:`
  dari frontmatter — tanpa triggers, `SkillRegistry.match` tidak pernah
  cocok sehingga loop tidak akan pernah tertutup.
- **Dedup:** sintesis slug yang sudah ada tidak lagi me-register ulang
  objek Skill (sebelumnya mereset status promosi + metrik uses/successes).
- **DI:** `TikoRuntime.create()` menerima `skills` (SkillRegistry) dan
  `selfLearningEngine` opsional untuk injeksi testing/host.
- **Bukti golden:** `packages/tiko_runtime/test/golden_skill_loop_test.dart`
  membuktikan loop tertutup end-to-end: tugas kompleks (2 tool calls) →
  file `skills/deploy-checklist/SKILL.md` muncul (status draft) → gerbang
  promosi `evaluateSkill(promoteOnPass: true)` lulus scan + golden evaluasi
  terisolasi → status trial → tugas mirip berikutnya ter-trigger
  (`uses` bertambah via `recordUse`) → file skill durable dimuat ulang oleh
  registry baru.

## P1-9 — MCP HTTP reconnect + recovery

Sumber: `packages/agent_tools/lib/src/mcp/http_client.dart`.

- **SSE reconnect:** stream GET event-stream yang error/ditutup server kini
  di-reconnect dengan backoff eksponensial terbatas (3 attempt berturut-turut,
  counter reset setelah koneksi sukses); tiap disconnect/reconnect tercatat
  di `transportErrors`.
- **Session-expiry recovery:** HTTP 404 ketika memegang session id dianggap
  session expired: koneksi SSE lama dibatalkan, session/protocol di-reset,
  re-initialize, lalu request direplay **tepat sekali** (guard `_recovering`
  mencegah loop rekursi). Aman untuk `tools/call` karena 404 berarti call
  tidak pernah dieksekusi server.
- **Tes:** `packages/agent_tools/test/mcp_http_reconnect_test.dart` —
  (1) server restart dengan session id baru di tengah percakapan:
  `tools/call` sukses transparan, initialize tepat 2×, call tidak dobel;
  (2) SSE diputus server dua kali: client reconnect, menerima
  `notifications/round-1` dan `round-2`, berhenti saat server menjawab 405.

## P1-10 — Docs happy-path browser / image / voice

- **Dokumen baru:** `docs/10-HAPPY-PATH-MANUAL.md` — cara uji manual
  `cdp_browser` (env `TIKO_CHROME_PATH`/`CHROME_PATH`/`CHROMIUM_PATH`),
  `cloud_browser` (`BROWSERBASE_API_KEY`+`BROWSERBASE_PROJECT_ID` atau
  `BROWSER_USE_API_KEY`), `generate_image` (config `features:` +
  SecretRef `env:FAL_KEY`), STT Telegram (`WHISPER_BIN`/`STT_API_KEY`/
  `STT_API_BASE`), dan TTS (library `TtsProviderFactory`: openai-tts/xai/
  elevenlabs/minimax + `DiscordVoiceLoop`) — semua nama env diverifikasi
  terhadap source, dengan tabel checklist status.
- **Gap wiring yang ditemukan dan diperbaiki:** `enableImageGeneration`,
  `enableVision`, `falApiKeyRef`, `openaiApiKeyRef` sebelumnya tidak pernah
  di-parse dari YAML (tidak mungkin diaktifkan via config). Kini section
  `features:` diparse dengan validasi tipe + aturan SecretRef yang sama
  dengan `search.tavily_api_key`; contoh ditambahkan di `config/agent.yaml`.
- **Tes config:** 2 kasus baru di `tiko_config_test.dart` (parsing flags +
  penolakan secret mentah).

## Verifikasi

- `dart analyze` bersih (0 error/warning) di semua package yang berubah:
  agent_core, agent_memory, agent_tools, tiko_runtime.
- `dart test` hijau: agent_memory (termasuk 8 tes baru), agent_tools
  (termasuk 4 + 2 tes baru), tiko_runtime 84 tes (termasuk golden
  closed-loop + 2 tes config baru).
