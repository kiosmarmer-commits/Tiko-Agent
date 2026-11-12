# Paritas Hermes — Penutupan Gap Utama: 10 November 2026

**Status:** Implemented (kode + unit test). Dart/Flutter SDK tidak tersedia di lingkungan penyusunan; validasi penuh ditunggu pada CI.

Dokumen ini mendeskripsikan implementasi tiga gap terbesar hasil perbandingan dengan Hermes Agent: plugins system + memory providers eksternal, prompt caching, dan API server OpenAI-compatible + ACP IDE integration.

## 1. Plugins System

**Modul:** `packages/agent_core/lib/src/plugin_system.dart`
**Test:** `packages/agent_core/test/plugin_system_test.dart`

Tiga tipe plugin ala Hermes, semua tanpa dependency baru:

- **General plugins** — `Plugin` dengan hook lifecycle: `beforeToolCall` (veto via `HookVerdict.deny` atau rewrite args via `HookVerdict.modify`), `afterToolCall`, `onSessionStart/End`, `onMessage`. `PluginRegistry` menjalankan hook berurutan; **plugin pertama yang menolak menang**; exception plugin terisolasi dan tercatat sebagai `PluginEvent` — loop agent tidak pernah mati karena plugin.
- **Memory providers** — kontrak `MemoryProvider` (`upsert`/`search`/`forget` + `MemoryRecord`), diimplementasi adapter eksternal di `agent_memory` (lihat §2).
- **Context engines** — kontrak `ContextEngine.buildContext()` untuk strategi perakitan konteks alternatif.

Registrasi nama sama menggantikan instance lama (dispose dipanggil). Pemakaian:

```dart
final plugins = PluginRegistry();
await plugins.register(MyGuardPlugin());
final verdict = await plugins.dispatchBeforeToolCall(
    ToolHookInput(toolName: 'shell', args: cmd, sessionId: sid));
if (!verdict.allowed) return; // veto
```

## 2. Memory Providers Eksternal

**Modul:** `packages/agent_memory/lib/src/memory_providers.dart`
**Test:** `packages/agent_memory/test/memory_providers_test.dart`

- `HttpMemoryProvider` — adapter REST untuk backend eksternal (RetainDB/ByteRover/Mem0-style atau self-hosted): `POST /memories`, `POST /memories/search`, `DELETE /memories/{id}`; auth Bearer opsional; retry dengan delay linear; memakai `dart:io HttpClient` (tanpa dependency baru).
- `MemoryProviderRouter` — write fan-out ke store lokal + semua provider eksternal; read merge dengan bobot per-provider (`weights`), dedupe by (owner, text) mempertahankan skor tertinggi; policy `interleave` atau `fallback` (pakai lokal sampai hit < threshold).
- **Prinsip degradasi:** kegagalan satu provider tidak menghentikan retrieval; error hanya dilempar bila semua provider gagal.
- Test memakai stub server HTTP loopback nyata (port ephemeral).

## 3. Prompt Caching

**Modul:** `packages/agent_providers/lib/src/prompt_cache.dart`
**Test:** `packages/agent_providers/test/prompt_cache_test.dart`
**Integrasi:** `AnthropicProvider(promptCache: ...)` di `anthropic_compat.dart`

- `PromptCacheManager` — melacak prefix stabil (model + system prompt + toolset hash) lintas sesi dengan TTL 1 jam, eviksi LRU di `maxEntries`, statistik hit/miss/eviction (`PromptCacheStats`). Prefix pendek (< `minPrefixChars`) tidak di-cache.
- `AnthropicCacheBreaker` — membangun blok `system` Anthropic dengan `cache_control: {"type": "ephemeral"}`; prompt panjang dipecah maksimal 4 breakpoint (batas provider) pada batas paragraf sehingga pertumbuhan prefix hanya meng-invalidate blok ekor.
- `estimatedSavings()` — estimasi hemat biaya dengan faktor cache-read 0.1.
- `AnthropicProvider` otomatis memasang breakpoint saat `promptCache` disuntik; tanpa injeksi, perilaku tidak berubah.

## 4. API Server OpenAI-Compatible

**Modul:** `packages/agent_tools/lib/src/openai_api.dart`
**Test:** `packages/agent_tools/test/openai_api_test.dart`

- `POST /v1/chat/completions` — format wire OpenAI penuh: non-streaming (`chat.completion` + `usage`) dan streaming SSE (`chat.completion.chunk` + `data: [DONE]`).
- `GET /v1/models` — daftar model `{"object": "list"}`.
- `GET /health` — tanpa auth; route lain wajib `Authorization: Bearer`.
- Error mengikuti format OpenAI (`error.type`: `authentication_error`, `invalid_request_error`, `server_error`).
- Handler agent disuntik (`OpenAiChatHandler`), default bind `127.0.0.1`, port ephemeral didukung (`port: 0`). Kompatibel dengan Open WebUI/LobeChat/LibreChat.

## 5. ACP IDE Integration

**Modul:** `packages/agent_tools/lib/src/acp_agent.dart`
**Test:** `packages/agent_tools/test/acp_agent_test.dart`

Agent-side Agent Client Protocol (JSON-RPC 2.0, ndjson over stdio) — protokol yang sama dipakai Zed/VS Code/JetBrains:

| Method | Perilaku |
|---|---|
| `initialize` | `protocolVersion`, `agentCapabilities`, `agentInfo` |
| `session/new` | session id baru |
| `session/prompt` | menjalankan handler, streaming `session/update` (`agent_message_chunk`), hasil `{stopReason: end_turn}` |
| `session/cancel` | menandai sesi cancel → `stopReason: cancelled` |
| `session/load` | error `-32601` (belum didukung) |

Prompt diterima sebagai `ContentBlock[]` (blok `text` digabung) atau string polos. Kegagalan handler menghasilkan `stopReason: error` + update `error`, bukan crash protokol. I/O bisa diinjeksi (stdin/stdout di produksi, StreamController di test).

## Cakupan dan batasan

- Modul berdiri sendiri dengan injection mengikuti pola repo; wiring penuh ke `TikoRuntime` (mendaftarkan plugin dari config, menjalankan `OpenAiCompatServer`/`AcpAgent` dari daemon) adalah langkah lanjutan yang tidak mengubah kontrak publik.
- ACP: belum mendukung `fs/*` client-side methods dan permission requests; cukup untuk chat + streaming chunk.
- Prompt cache: marker Anthropic-style; provider lain mengabaikan blok cache (fallback aman).

---

# Addendum v4.0 — Gap 4-6 (cloud browser, Discord voice, media breadth, Skills Hub)

## 6. Cloud Browser Backends

**Modul:** `packages/agent_tools/lib/src/browser_backends.dart`
**Test:** `packages/agent_tools/test/browser_backends_test.dart`
**Perubahan terkait:** `CdpSession` kini menerima `wsEndpoint` opsional — saat diisi, CDP terhubung ke WebSocket remote tanpa meluncurkan Chromium lokal.

- `BrowserbaseBackend` — REST v1 Browserbase: `POST /v1/sessions` (header `x-api-key`, body opsional `projectId`/`region`) → `id` + `connectUrl` (CDP WebSocket) + `debugUrl`; sesi ditutup dengan `POST /v1/sessions/{id}`.
- `BrowserUseBackend` — REST Browser Use: `POST /api/v1/sessions` (Bearer) → `id` + `cdp_url` + `live_url`; ditutup dengan `DELETE /api/v1/sessions/{id}`.
- `CloudBrowserRouter` — mencoba backend sesuai urutan prioritas; backend pertama yang berhasil membuka koneksi CDP menang. Bila semua gagal (atau daftar kosong) dan `localFallback: true`, router meluncurkan Chromium lokal — meniru dualitas lokal/cloud Hermes Agent. `CloudBrowserHandle.release()` menutup CDP session dan menghentikan sesi cloud.
- Error HTTP → `BrowserBackendException`; kegagalan `open()` pada satu backend otomatis lanjut ke backend berikutnya.

## 7. Discord Voice

**Modul:** `packages/agent_gateway/lib/src/discord_voice.dart`
**Test:** `packages/agent_gateway/test/discord_voice_test.dart`

- `DiscordVoiceClient.join()` — handshake lengkap: `PATCH /guilds/{id}/voice-states/@me` (join channel) → menunggu dispatch `VOICE_STATE_UPDATE` + `VOICE_SERVER_UPDATE` (diteruskan ke `handleDispatch` dari gateway teks) → voice WebSocket `wss://{endpoint}?v=4` → op 10 Hello → heartbeat op 3 → op 0 Identify (`server_id`, `user_id`, `session_id`, `token`) → op 2 Ready (`ssrc`, ip, port, modes) → discovery UDP 74-byte (type 0x1 + length 0x46 + ssrc + alamat 64B + port 2B, big-endian) → op 4 Select Protocol → op 6 Session Description.
- `sendOpusFrame()` — header RTP 12-byte + nonce + enkripsi lewat `VoiceEncryptor` yang pluggable. `xsalsa20_poly1305` wajib oleh Discord dan belum tersedia murni di Dart (`UnsupportedVoiceEncryptor` melempar `UnsupportedError`); sediakan implementasi FFI sodium untuk transmisi nyata.
- `DiscordVoiceLoop` — orkestrasi percakapan: STT (frame opus → teks) → handler → TTS (teks → frame opus) → transmisi dengan op 5 Speaking.
- `VoiceSocket` dan `VoiceUdpSocket` adalah interface yang dapat diinjeksi (`IoVoiceSocket`/`IoVoiceUdpSocket` untuk produksi, fake di test) sehingga handshake dapat diuji tanpa jaringan nyata.

## 8. Image Generation & TTS Provider Breadth

**Modul:** `packages/agent_tools/lib/src/image_providers.dart`
**Test:** `packages/agent_tools/test/image_providers_test.dart`
**Modul TTS:** `packages/agent_gateway/lib/src/tts_providers.dart`
**Test TTS:** `packages/agent_gateway/test/tts_providers_test.dart`

Image (menyatu dengan `ImageProvider` abstrak yang sudah ada di `image_generation.dart`):

- `ImageModelCatalog` — 11 model paritas Hermes: FLUX 2 Klein/Pro, GPT-Image 1.5/2, Nano Banana Pro, Ideogram V3, Recraft V4 Pro, Qwen Image, Z-Image Turbo, Krea V2 Medium/Large.
- `FalAiImageProvider` — queue API FAL.ai: `POST https://queue.fal.run/{model}` → polling `status_url` sampai `COMPLETED` → `GET response_url` → unduh `images[].url`.
- `OpenAiImagesProvider` — `POST /v1/images/generations`, mendukung respons `b64_json` maupun `url`.
- `ImageModelRouter` — dispatch berdasarkan prefix model (`fal-ai/...` → FAL.ai, `openai/...` → OpenAI).

TTS (menyatu dengan `TtsProvider` abstrak di `tts.dart`):

- `HttpTtsProvider` — provider HTTP generik berbasis template (placeholder `{{text_json}}`, `{{text}}`, `{{voice}}`, `{{model}}`); dukung respons byte mentah maupun field JSON bertitik (`data.audio`, `candidates.0.content.parts.0.inlineData.data`) dengan decoding base64/hex.
- `CommandTtsProvider` — engine CLI lokal (Edge TTS, Piper, atau perintah kustom) via `Process.run`; membaca audio dari file output (`{{output}}`) atau stdout biner.
- `TtsProviderCatalog` — 10 provider paritas Hermes: edge-tts, elevenlabs, openai-tts, minimax, mistral-voxtral, google-gemini, xai, neutts, kittentts, piper.
- `TtsProviderFactory` — membangun provider dari id katalog; `xai` memakai endpoint OpenAI-compatible, `custom` wajib menyertakan `commandTemplate`.

## 9. agentskills.io Compatibility + Skills Hub

**Modul:** `packages/agent_core/lib/src/agentskills_io.dart`
**Test:** `packages/agent_core/test/agentskills_io_test.dart`
**Modul Hub:** `packages/agent_tools/lib/src/skills_hub.dart`
**Test Hub:** `packages/agent_tools/test/skills_hub_test.dart`
**Dependency baru:** `crypto: ^3.0.0` pada `agent_tools` (sudah ada di workspace).

- `AgentSkillManifest` — parse/validasi/serialisasi `SKILL.md` standar agentskills.io: frontmatter YAML wajib `name` (pola `^[a-z0-9][a-z0-9-]*$`, ≤64 karakter) dan `description` (≤1024 karakter), opsional `license`, `allowed-tools`, `metadata`; deskripsi yang mengandung `:`/`#`/`'` dikutip otomatis dan selamat round-trip.
- `AgentSkillConverter` — konversi dua arah antara skill standar dan `Skill` Tiko: `allowed-tools` → `tools`, `metadata.triggers` → `triggers`, status impor selalu `trial`.
- `SkillsHubClient` — klien marketplace REST: `search` (`GET /skills?q=`), `fetch`, `install` (pipeline keamanan: checksum sha256 atas JSON kanonik files → manifest valid → `SkillScanner` untuk setiap file → proteksi path traversal → tulis ke direktori skill → catat `installed.json`), `uninstall`, `refreshInstalled`. Auth Bearer opsional; file korup di `installed.json` ditoleransi.
